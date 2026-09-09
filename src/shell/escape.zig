//! Экранирование значений для каждой поддерживаемой оболочки.
//!
//! Это защитная граница: значение переменной приходит из `.env`-файла или от
//! плагина секретов, а уезжает в `eval` пользовательской оболочки. Любая
//! дырка здесь — исполнение произвольного кода. Каждая функция покрыта
//! round-trip тестом на живой оболочке (см. низ файла).
//!
//! Порт `internal/shell/escape.go` и Escape-функций адаптеров из
//! `internal/shell/shell.go`. Основа bash-варианта — реализация direnv.
//!
//! Владение: `write*`-функции ничего не выделяют и пишут в переданный writer;
//! `*Escape`-обёртки выделяют результат в переданном аллокаторе.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Символы, которые в bash безопасны без кавычек.
fn isBashSafe(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '.', '/', '-', '_', ':', '=', ',', '+', '@', '%' => true,
        else => false,
    };
}

fn hasControlOrHighBit(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f or c >= 0x80) return true;
    }
    return false;
}

/// Значение, пригодное для подстановки в bash/zsh как один токен.
///
/// Стратегия:
///   - пустая строка → `''`;
///   - только безопасные символы → как есть;
///   - есть управляющие или не-ASCII байты → ANSI-C `$'...'`;
///   - иначе → одинарные кавычки с заменой `'` на `'\''`.
pub fn writeBashEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len == 0) return w.writeAll("''");
    if (hasControlOrHighBit(s)) return writeAnsiC(w, s);

    var needs_quoting = false;
    for (s) |c| {
        if (!isBashSafe(c)) {
            needs_quoting = true;
            break;
        }
    }
    if (!needs_quoting) return w.writeAll(s);
    return writeSingleQuoted(w, s);
}

/// Всегда оборачивает в одинарные кавычки, экранируя внутренние как `'\''`.
pub fn writeSingleQuoted(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('\'');
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |i| {
        try w.writeAll(rest[0..i]);
        try w.writeAll("'\\''");
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
    try w.writeByte('\'');
}

/// ANSI-C цитирование `$'...'` — для управляющих и не-ASCII байтов.
///
/// Обратный слэш и одинарная кавычка обязаны экранироваться: внутри `$'...'`
/// слэш начинает escape-последовательность, а неэкранированная кавычка
/// закрывает строку и отдаёт остаток значения оболочке как код.
pub fn writeAnsiC(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len == 0) return w.writeAll("''");

    // Go собирает тело в буфер и решает по флагу, нужна ли обёртка `$'...'`.
    // Здесь то же решение принимается заранее одним проходом.
    var needs_wrapper = false;
    for (s) |c| {
        switch (c) {
            '\n', '\r', '\t', '\\', '\'' => needs_wrapper = true,
            else => if (c < 0x20 or c >= 0x7f) {
                needs_wrapper = true;
            },
        }
        if (needs_wrapper) break;
    }

    if (needs_wrapper) try w.writeAll("$'");
    for (s) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            else => {
                if (c < 0x20 or c >= 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    if (needs_wrapper) try w.writeByte('\'');
}

/// Экранирование для вставки внутрь двойных кавычек bash.
pub fn writeDoubleQuoteEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '$' => try w.writeAll("\\$"),
            '`' => try w.writeAll("\\`"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

/// Экранирование аргумента fish.
///
/// Внутри одинарных кавычек fish распознаёт только `\'` и `\\`. Слэш должен
/// удваиваться ПЕРВЫМ: иначе значение, оканчивающееся на слэш, экранирует
/// закрывающую кавычку и остаток строки становится кодом.
pub fn writeFishEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len == 0) return w.writeAll("''");
    try w.writeByte('\'');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('\'');
}

/// Экранирование значения для nushell (двойные кавычки).
pub fn writeNuEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len == 0) return w.writeAll("\"\"");
    try w.writeByte('"');
    // Go итерирует по рунам, но каждая ветка, кроме перечисленных ASCII,
    // пишет руну обратно байт в байт. Побайтовый проход даёт тот же
    // результат на валидном UTF-8 и, в отличие от Go, не подменяет
    // невалидные байты на U+FFFD.
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '$' => try w.writeAll("\\$"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Экранирование для одинарных кавычек PowerShell: внутренняя кавычка удваивается.
pub fn writePwshEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    if (s.len == 0) return w.writeAll("''");
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
}

// ---- alloc-обёртки ---------------------------------------------------------

fn allocEscape(
    gpa: Allocator,
    s: []const u8,
    comptime writeFn: fn (*Writer, []const u8) Writer.Error!void,
) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    // Writer.Allocating падает только по OutOfMemory.
    writeFn(&aw.writer, s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn bashEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeBashEscaped);
}

pub fn singleQuote(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeSingleQuoted);
}

pub fn ansiCEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeAnsiC);
}

pub fn doubleQuoteEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeDoubleQuoteEscaped);
}

pub fn fishEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeFishEscaped);
}

pub fn nuEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writeNuEscaped);
}

pub fn pwshEscape(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return allocEscape(gpa, s, writePwshEscaped);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "bashEscape: table from Go TestBashEscapeBasic" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "''" },
        .{ .in = "hello", .want = "hello" },
        .{ .in = "hello world", .want = "'hello world'" },
        .{ .in = "it's", .want = "'it'\\''s'" },
        .{ .in = "$VAR", .want = "'$VAR'" },
        .{ .in = "\"quoted\"", .want = "'\"quoted\"'" },
        .{ .in = "`backtick`", .want = "'`backtick`'" },
        .{ .in = "plain/path/to/file.txt", .want = "plain/path/to/file.txt" },
        .{ .in = "http://example.com:8080", .want = "http://example.com:8080" },
    };
    for (cases) |c| {
        const got = try bashEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "bashEscape: control characters use ANSI-C quoting" {
    const got = try bashEscape(testing.allocator, "line1\nline2");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("$'line1\\nline2'", got);
}

test "bashEscape: ANSI-C form escapes quote and backslash" {
    // Полезная нагрузка, которая раньше выходила из $'...' и отдавала
    // остаток значения оболочке как код.
    const got = try bashEscape(testing.allocator, "a\nb'; echo INJECTED; '");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("$'a\\nb\\'; echo INJECTED; \\''", got);

    const tail = try bashEscape(testing.allocator, "a\nb\\");
    defer testing.allocator.free(tail);
    try testing.expectEqualStrings("$'a\\nb\\\\'", tail);
}

test "bashEscape: non-ASCII becomes hex bytes" {
    // "é" — две UTF-8-байты, обе >= 0x80.
    const got = try bashEscape(testing.allocator, "é");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("$'\\xc3\\xa9'", got);
}

test "singleQuote: table from Go TestSingleQuote" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "''" },
        .{ .in = "hello", .want = "'hello'" },
        .{ .in = "it's", .want = "'it'\\''s'" },
        // Каждая из трёх кавычек превращается в 4 символа '\'' ; сверено
        // с Go-эталоном.
        .{ .in = "'''", .want = "''\\'''\\'''\\'''" },
    };
    for (cases) |c| {
        const got = try singleQuote(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "doubleQuoteEscape" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "" },
        .{ .in = "plain", .want = "plain" },
        .{ .in = "$HOME", .want = "\\$HOME" },
        .{ .in = "a\"b", .want = "a\\\"b" },
        .{ .in = "back\\slash", .want = "back\\\\slash" },
        .{ .in = "`id`", .want = "\\`id\\`" },
        .{ .in = "a\nb\tc\rd", .want = "a\\nb\\tc\\rd" },
    };
    for (cases) |c| {
        const got = try doubleQuoteEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "fishEscape: backslash is doubled before the quote is escaped" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "''" },
        .{ .in = "plain", .want = "'plain'" },
        .{ .in = "it's", .want = "'it\\'s'" },
        .{ .in = "ends_with\\", .want = "'ends_with\\\\'" },
        .{ .in = "a\\'b", .want = "'a\\\\\\'b'" },
    };
    for (cases) |c| {
        const got = try fishEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "nuEscape" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "\"\"" },
        .{ .in = "plain", .want = "\"plain\"" },
        .{ .in = "say \"hi\"", .want = "\"say \\\"hi\\\"\"" },
        .{ .in = "$HOME", .want = "\"\\$HOME\"" },
        .{ .in = "a\\b", .want = "\"a\\\\b\"" },
        .{ .in = "a\nb", .want = "\"a\\nb\"" },
        .{ .in = "Привет", .want = "\"Привет\"" },
    };
    for (cases) |c| {
        const got = try nuEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "pwshEscape: inner quote is doubled" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "''" },
        .{ .in = "plain", .want = "'plain'" },
        .{ .in = "it's", .want = "'it''s'" },
        .{ .in = "'''", .want = "''''''''" },
    };
    for (cases) |c| {
        const got = try pwshEscape(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

// ---- round trip через живые оболочки ---------------------------------------

/// Значения, которые может выдать враждебный (или просто неудобный)
/// `.env`-файл или плагин секретов. Каждое обязано пережить круг через
/// оболочку байт в байт и ничего при этом не выполнить.
///
/// NUL исключён: он в принципе не проходит через окружение процесса.
const evil_values = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "plain", .value = "hello" },
    .{ .name = "empty", .value = "" },
    .{ .name = "space", .value = "a b" },
    .{ .name = "single_quote", .value = "it's" },
    .{ .name = "double_quote", .value = "say \"hi\"" },
    .{ .name = "backslash", .value = "back\\slash" },
    .{ .name = "trailing_backslash", .value = "ends_with\\" },
    .{ .name = "double_backslash", .value = "a\\\\b" },
    .{ .name = "dollar", .value = "$HOME and ${PATH}" },
    .{ .name = "backtick", .value = "`id`" },
    .{ .name = "subshell", .value = "$(id)" },
    .{ .name = "semicolon", .value = "a;b" },
    .{ .name = "bang", .value = "history!expansion" },
    .{ .name = "newline", .value = "line1\nline2" },
    .{ .name = "crlf", .value = "line1\r\nline2" },
    .{ .name = "tab", .value = "a\tb" },
    .{ .name = "utf8", .value = "Привет, мир" },
    .{ .name = "emoji", .value = "🎉 done" },
    .{ .name = "utf8_with_quote", .value = "don't — не надо" },
    .{ .name = "glob", .value = "*.go ?x [a-z]" },
    .{ .name = "pipe_redirect", .value = "a | b > c < d & e" },
    // Ровно та нагрузка, которая когда-то выходила из $'...' и отдавала
    // остаток значения оболочке как код.
    .{ .name = "ansi_c_breakout", .value = "a\nb'; echo INJECTED-COMMAND-RAN; '" },
    .{ .name = "ansi_c_backslash_breakout", .value = "a\nb\\" },
    .{ .name = "quote_then_newline", .value = "'\n'" },
    .{ .name = "only_quotes", .value = "'''" },
};

/// Запускает `<shell> -c "printf '%s' <escaped>"` и возвращает stdout.
/// Возвращает null, если оболочки нет на машине.
fn runEscapeRoundTrip(
    gpa: Allocator,
    shell_bin: []const u8,
    escaped: []const u8,
) !?[]u8 {
    const script = try std.fmt.allocPrint(gpa, "printf '%s' {s}", .{escaped});
    defer gpa.free(script);

    const result = std.process.run(gpa, testing.io, .{
        .argv = &.{ shell_bin, "-c", script },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s} exited {d} on script: {s}\n", .{ shell_bin, code, script });
            return error.ShellFailed;
        },
        else => return error.ShellFailed,
    }
    return result.stdout;
}

fn expectRoundTrip(
    shell_bin: []const u8,
    comptime writeFn: fn (*Writer, []const u8) Writer.Error!void,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var skipped = false;
    for (evil_values) |tc| {
        const escaped = try allocEscape(a, tc.value, writeFn);
        const got = (try runEscapeRoundTrip(a, shell_bin, escaped)) orelse {
            skipped = true;
            break;
        };
        testing.expectEqualStrings(tc.value, got) catch |err| {
            std.debug.print("case {s}: escaped as {s}\n", .{ tc.name, escaped });
            return err;
        };
        // Ни один случай не должен привести к исполнению кода.
        try testing.expect(std.mem.indexOf(u8, got, "INJECTED-COMMAND-RAN") == null or
            std.mem.indexOf(u8, tc.value, "INJECTED-COMMAND-RAN") != null);
    }
    if (skipped) return error.SkipZigTest;
}

test "round trip through bash" {
    try expectRoundTrip("bash", writeBashEscaped);
}

test "round trip through zsh" {
    try expectRoundTrip("zsh", writeBashEscaped);
}

test "round trip through fish" {
    try expectRoundTrip("fish", writeFishEscaped);
}
