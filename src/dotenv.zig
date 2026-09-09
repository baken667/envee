//! Разбор формата `.env`.
//!
//! Ориентир формата: https://github.com/bkeepers/dotenv
//! Порт `internal/dotenv/parse.go`.
//!
//! Поддерживается:
//!   - `KEY=VALUE`, `KEY:VALUE`
//!   - префикс `export` (отбрасывается)
//!   - значения в одинарных кавычках (буквально, без escape и подстановок)
//!   - значения в двойных кавычках (escape, и `$VAR` при expand = true)
//!   - многострочные значения внутри кавычек (перевод строки сохраняется)
//!   - комментарии с `#` вне кавычек, пустые строки
//!
//! Реализация — конечный автомат в один проход. Регулярки в стиле direnv
//! оказались слишком хрупкими.
//!
//! Владение: `Vars` владеет и ключами, и значениями (они конструируются, а
//! не нарезаются из входа), поэтому у него есть `deinit`. В проде живёт в
//! арене процесса, и `deinit` не нужен.

const std = @import("std");
const Allocator = std.mem.Allocator;

const env = @import("env.zig");

/// Результат разбора. Порядок вставки сохраняется — он совпадает с порядком
/// строк в файле, что важно и для детерминизма вывода, и для диагностики.
pub const Vars = struct {
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub const empty: Vars = .{};

    pub fn deinit(v: *Vars, gpa: Allocator) void {
        for (v.map.keys()) |k| gpa.free(k);
        for (v.map.values()) |val| gpa.free(val);
        v.map.deinit(gpa);
    }

    pub fn get(v: Vars, key: []const u8) ?[]const u8 {
        return v.map.get(key);
    }

    pub fn count(v: Vars) usize {
        return v.map.count();
    }

    pub fn keys(v: Vars) []const []const u8 {
        return v.map.keys();
    }

    /// Забирает владение key и value. При повторном ключе освобождает то,
    /// что перестало быть нужным, — иначе перезапись переменной в одном
    /// файле давала бы утечку.
    fn putOwned(v: *Vars, gpa: Allocator, key: []u8, value: []u8) Allocator.Error!void {
        const gop = try v.map.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(key);
            gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = value;
    }
};

/// Место ошибки. Отдельная структура, потому что error set в Zig не носит
/// полезной нагрузки. На шаге 8 сольётся с общей диагностикой из errs.zig.
pub const Diagnostics = struct {
    line: usize = 0,
};

pub const Error = error{
    UnterminatedSingleQuote,
    UnterminatedDoubleQuote,
} || Allocator.Error;

/// Источник значений для подстановки `$VAR`. null — подстановка выключена.
pub const Expansion = ?*const env.Map;

pub fn parse(gpa: Allocator, data: []const u8, diag: ?*Diagnostics) Error!Vars {
    return parseInner(gpa, data, null, diag);
}

/// Как `parse`, но внутри значений в двойных кавычках раскрывает `$VAR`,
/// `${VAR}` и `${VAR:-default}` по переданному окружению.
///
/// Используется, когда у директивы `_.file` стоит `expand = true`.
pub fn parseWithExpansion(
    gpa: Allocator,
    data: []const u8,
    source: *const env.Map,
    diag: ?*Diagnostics,
) Error!Vars {
    return parseInner(gpa, data, source, diag);
}

const State = enum {
    start,
    key,
    before_value,
    value,
    quoted_single,
    quoted_double,
    escape,
    line_comment,
};

fn parseInner(gpa: Allocator, raw: []const u8, expand: Expansion, diag: ?*Diagnostics) Error!Vars {
    var out: Vars = .empty;
    errdefer out.deinit(gpa);

    // Нормализуем CRLF до запуска автомата. Автомат считает концом строки
    // только '\n', и в файле, выгруженном с Windows-окончаниями, '\r'
    // проваливался дальше как обычный символ: каждое значение получало
    // хвостовой возврат каретки, а каждая пустая строка порождала
    // переменную с именем "\r". Escape `\r` внутри двойных кавычек — другая
    // сущность, и он обрабатывается отдельно.
    const data = try normalizeCrlf(gpa, raw);
    defer gpa.free(data);

    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(gpa);
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(gpa);

    var st: State = .start;
    var cur_line: usize = 1;
    var statement_line: usize = 1;

    // Записывает накопленную пару и очищает буферы. Пустой ключ не
    // записывается: так пустые строки и одинокие комментарии не превращаются
    // в переменные.
    const flush = struct {
        fn f(o: *Vars, g: Allocator, k: *std.ArrayList(u8), v: *std.ArrayList(u8)) Allocator.Error!void {
            if (k.items.len == 0) return;
            const owned_key = try k.toOwnedSlice(g);
            errdefer g.free(owned_key);
            const owned_value = try v.toOwnedSlice(g);
            errdefer g.free(owned_value);
            try o.putOwned(g, owned_key, owned_value);
            k.clearRetainingCapacity();
            v.clearRetainingCapacity();
        }
    }.f;

    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];

        switch (st) {
            .start, .before_value => {
                if (c == ' ' or c == '\t') continue;
                if (c == '#') {
                    st = .line_comment;
                    continue;
                }
                if (c == '\n') {
                    cur_line += 1;
                    if (st == .start) continue;
                    // Ключ был, значения нет — считаем значение пустым.
                    try flush(&out, gpa, &key, &value);
                    st = .start;
                    continue;
                }
                // Префикс `export`, за которым обязан идти пробел или таб.
                if (st == .start and isExportPrefixAt(data, i)) {
                    var j = i + "export".len;
                    while (j < data.len and (data[j] == ' ' or data[j] == '\t')) j += 1;
                    // Смещение обязано быть относительным. В Go здесь долго
                    // стояла константа 6, верная только когда `export` стоит
                    // в самом начале файла; в любом другом месте индекс
                    // уезжал НАЗАД и разбор зацикливался, подвешивая
                    // shell-hook на каждом приглашении.
                    i = j - 1;
                    st = .key;
                    statement_line = cur_line;
                    continue;
                }
                st = .key;
                statement_line = cur_line;
                try key.append(gpa, c);
            },

            .key => {
                if (c == '=' or c == ':') {
                    st = .value;
                    continue;
                }
                if (c == '\n') {
                    cur_line += 1;
                    try flush(&out, gpa, &key, &value);
                    st = .start;
                    continue;
                }
                if (c == '#') {
                    try flush(&out, gpa, &key, &value);
                    st = .line_comment;
                    continue;
                }
                // Всё, что не является допустимым символом ключа (например
                // пробелы вокруг `=`), молча отбрасывается.
                if (isKeyChar(c)) try key.append(gpa, c);
            },

            .value => {
                if (c == '"') {
                    st = .quoted_double;
                    continue;
                }
                if (c == '\'') {
                    st = .quoted_single;
                    continue;
                }
                if (c == '\n') {
                    cur_line += 1;
                    try flush(&out, gpa, &key, &value);
                    st = .start;
                    continue;
                }
                if (c == '#') {
                    // Пробелы перед комментарием в значение не входят.
                    const trimmed = std.mem.trimEnd(u8, value.items, " \t");
                    value.shrinkRetainingCapacity(trimmed.len);
                    try flush(&out, gpa, &key, &value);
                    st = .line_comment;
                    continue;
                }
                if (c == ' ' or c == '\t') {
                    if (value.items.len == 0) continue; // ведущие пробелы
                    try value.append(gpa, c);
                    continue;
                }
                try value.append(gpa, c);
            },

            .quoted_single => {
                // Буквально: ни escape, ни подстановок.
                if (c == '\'') {
                    st = .value;
                    continue;
                }
                if (c == '\n') cur_line += 1;
                try value.append(gpa, c);
            },

            .quoted_double => {
                if (c == '"') {
                    st = .value;
                    continue;
                }
                if (c == '\\') {
                    st = .escape;
                    continue;
                }
                if (c == '$') {
                    if (expand) |source| {
                        if (readDollarRef(data[i..])) |ref| {
                            const found = source.get(ref.name) orelse "";
                            // Пустое значение переменной равнозначно её
                            // отсутствию и уступает место умолчанию — так
                            // ведёт себя Go-эталон.
                            try value.appendSlice(gpa, if (found.len > 0) found else ref.default);
                            i += ref.len - 1; // -1: цикл сам прибавит единицу
                            continue;
                        }
                    }
                }
                if (c == '\n') cur_line += 1;
                try value.append(gpa, c);
            },

            .escape => {
                switch (c) {
                    'n' => try value.append(gpa, '\n'),
                    'r' => try value.append(gpa, '\r'),
                    't' => try value.append(gpa, '\t'),
                    '\\' => try value.append(gpa, '\\'),
                    '"' => try value.append(gpa, '"'),
                    '$' => try value.append(gpa, '$'),
                    // Неизвестный escape сохраняется как есть.
                    else => try value.appendSlice(gpa, &.{ '\\', c }),
                }
                st = .quoted_double;
            },

            .line_comment => {
                if (c == '\n') {
                    cur_line += 1;
                    st = .start;
                }
            },
        }
    }

    switch (st) {
        .value, .key, .quoted_double, .quoted_single => try flush(&out, gpa, &key, &value),
        else => {},
    }

    if (st == .quoted_single or st == .quoted_double) {
        if (diag) |d| d.line = statement_line;
        return switch (st) {
            .quoted_single => error.UnterminatedSingleQuote,
            else => error.UnterminatedDoubleQuote,
        };
    }

    return out;
}

fn normalizeCrlf(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, data.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        out[n] = data[i];
        n += 1;
    }
    return gpa.realloc(out, n);
}

/// true, если по смещению i начинается слово `export`, отделённое пробелом
/// или табом. `exportable=1` под это не подходит и остаётся именем ключа.
fn isExportPrefixAt(data: []const u8, i: usize) bool {
    const word = "export";
    if (i + word.len > data.len) return false;
    if (!std.mem.eql(u8, data[i..][0..word.len], word)) return false;
    if (i + word.len == data.len) return true;
    const next = data[i + word.len];
    return next == ' ' or next == '\t';
}

const DollarRef = struct {
    name: []const u8,
    /// Умолчание из `${VAR:-default}`, иначе пусто.
    default: []const u8,
    /// Сколько байт занимает вся ссылка вместе с `$`.
    len: usize,
};

/// Читает `$VAR`, `${VAR}` или `${VAR:-default}` в начале s.
/// null — на этом месте не ссылка (например `$` перед не-идентификатором).
fn readDollarRef(s: []const u8) ?DollarRef {
    if (s.len == 0 or s[0] != '$') return null;

    if (s.len > 1 and s[1] == '{') {
        const end = std.mem.indexOfScalar(u8, s[2..], '}') orelse return null;
        const body = s[2 .. 2 + end];
        if (std.mem.indexOf(u8, body, ":-")) |idx| {
            return .{ .name = body[0..idx], .default = body[idx + 2 ..], .len = 2 + end + 1 };
        }
        return .{ .name = body, .default = "", .len = 2 + end + 1 };
    }

    var i: usize = 1;
    while (i < s.len and isIdentChar(s[i])) i += 1;
    if (i == 1) return null; // `$` перед символом, не начинающим имя
    return .{ .name = s[1..i], .default = "", .len = i };
}

fn isIdentChar(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}

/// Допустимые символы ключа: буквы, цифры, подчёркивание, точка.
fn isKeyChar(c: u8) bool {
    return isIdentChar(c) or c == '.';
}

/// Читает и разбирает файл `.env` с диска.
pub fn parseFile(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    diag: ?*Diagnostics,
) !Vars {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(data);
    return parse(gpa, data, diag);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn printKeys(vars: Vars) void {
    std.debug.print("have keys:", .{});
    for (vars.keys()) |k| std.debug.print(" {s}", .{k});
    std.debug.print("\n", .{});
}

/// Разбирает и сверяет полный набор пар. Проверяется и состав, и то, что
/// лишних ключей не появилось.
fn expectVars(src: []const u8, want: []const struct { []const u8, []const u8 }) !void {
    var vars = try parse(testing.allocator, src, null);
    defer vars.deinit(testing.allocator);

    for (want) |pair| {
        const got = vars.get(pair[0]) orelse {
            std.debug.print("missing key {s}; ", .{pair[0]});
            printKeys(vars);
            return error.TestExpectedEqual;
        };
        testing.expectEqualStrings(pair[1], got) catch |err| {
            std.debug.print("key {s}\n", .{pair[0]});
            return err;
        };
    }
    testing.expectEqual(want.len, vars.count()) catch |err| {
        printKeys(vars);
        return err;
    };
}

test "basic pairs" {
    try expectVars(
        \\
        \\KEY1=value1
        \\KEY2=value2
        \\KEY3=value with spaces
        \\
    , &.{
        .{ "KEY1", "value1" },
        .{ "KEY2", "value2" },
        .{ "KEY3", "value with spaces" },
    });
}

test "export prefix is stripped" {
    try expectVars("export FOO=bar", &.{.{ "FOO", "bar" }});
}

test "quoted and empty values" {
    try expectVars(
        \\
        \\SINGLE='single value'
        \\DOUBLE="double value"
        \\EMPTY=
        \\
    , &.{
        .{ "SINGLE", "single value" },
        .{ "DOUBLE", "double value" },
        .{ "EMPTY", "" },
    });
}

test "comments, whole-line and inline" {
    try expectVars(
        \\
        \\# This is a comment
        \\KEY1=value1  # inline comment
        \\# Another comment
        \\KEY2=value2
        \\
    , &.{
        .{ "KEY1", "value1" },
        .{ "KEY2", "value2" },
    });
}

test "multi-line value inside quotes" {
    try expectVars(
        \\MULTI="line1
        \\line2
        \\line3"
        \\KEY=after
        \\
    , &.{
        .{ "MULTI", "line1\nline2\nline3" },
        .{ "KEY", "after" },
    });
}

test "equals signs inside a value" {
    try expectVars(
        \\URL="postgres://user:pass@host:5432/db?sslmode=require"
    , &.{.{ "URL", "postgres://user:pass@host:5432/db?sslmode=require" }});
}

test "dotted keys, and spaces around the equals sign" {
    try expectVars(
        \\app.name = "myapp"
        \\app.version = "1.0.0"
        \\
    , &.{
        .{ "app.name", "myapp" },
        .{ "app.version", "1.0.0" },
    });
}

test "colon as the separator" {
    try expectVars("KEY:value\n", &.{.{ "KEY", "value" }});
}

test "escapes inside double quotes" {
    try expectVars(
        \\A="tab\there"
        \\B="newline\nhere"
        \\C="quote\"here"
        \\D="dollar\$here"
        \\E="backslash\\here"
        \\F="unknown\qescape"
        \\
    , &.{
        .{ "A", "tab\there" },
        .{ "B", "newline\nhere" },
        .{ "C", "quote\"here" },
        .{ "D", "dollar$here" },
        .{ "E", "backslash\\here" },
        .{ "F", "unknown\\qescape" },
    });
}

test "single quotes are literal" {
    try expectVars(
        \\A='no \n escape and no $VAR'
        \\
    , &.{.{ "A", "no \\n escape and no $VAR" }});
}

// Файл `.env`, выгруженный на Windows, приходит с CRLF. Автомат считает
// концом строки только '\n', поэтому до нормализации каждое значение
// сохраняло возврат каретки, а пустые строки давали переменную с именем
// "\r". Поймано джобом windows-latest в CI.
test "CRLF line endings" {
    var vars = try parse(testing.allocator, "# comment\r\n" ++
        "LOG_FORMAT=json\r\n" ++
        "\r\n" ++
        "LOG_LEVEL = info\r\n" ++
        "export QUOTED=\"has spaces\"\r\n" ++
        "SINGLE='single quoted'\r\n", null);
    defer vars.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), vars.count());
    try testing.expectEqualStrings("json", vars.get("LOG_FORMAT").?);
    try testing.expectEqualStrings("info", vars.get("LOG_LEVEL").?);
    try testing.expectEqualStrings("has spaces", vars.get("QUOTED").?);
    try testing.expectEqualStrings("single quoted", vars.get("SINGLE").?);
    for (vars.keys()) |k| {
        try testing.expect(std.mem.indexOfAny(u8, k, "\r\n") == null);
    }
}

test "CRLF and LF files parse identically" {
    const lf = "A=1\nB=two words\nC=\"quoted\"\n";
    const crlf = "A=1\r\nB=two words\r\nC=\"quoted\"\r\n";

    var a = try parse(testing.allocator, lf, null);
    defer a.deinit(testing.allocator);
    var b = try parse(testing.allocator, crlf, null);
    defer b.deinit(testing.allocator);

    try testing.expectEqual(a.count(), b.count());
    for (a.keys(), 0..) |k, i| {
        try testing.expectEqualStrings(k, b.keys()[i]);
        try testing.expectEqualStrings(a.get(k).?, b.get(k).?);
    }
}

// Escape `\r` внутри двойных кавычек — не то же самое, что буквальный
// возврат каретки в файле, и обязан продолжать работать.
test "the \\r escape survives CRLF normalisation" {
    try expectVars("A=\"line1\\r\\nline2\"\n", &.{.{ "A", "line1\r\nline2" }});
}

// `export` на любой строке, кроме первой, раньше отправлял разбор назад и
// зацикливал его, подвешивая shell-hook на каждом приглашении: смещение
// после "export" было константой 6 вместо i+6.
test "export on a line other than the first terminates" {
    try expectVars("FIRST=1\nexport SECOND=2\nTHIRD=3\nexport   FOURTH=4\n", &.{
        .{ "FIRST", "1" },
        .{ "SECOND", "2" },
        .{ "THIRD", "3" },
        .{ "FOURTH", "4" },
    });
}

test "export edge cases" {
    try expectVars("export A=1\n", &.{.{ "A", "1" }});
    try expectVars("B=0\nexport\tA=1\n", &.{ .{ "B", "0" }, .{ "A", "1" } });
    // `exportable` — обычный ключ, а не префикс с хвостом.
    try expectVars("exportable=1\n", &.{.{ "exportable", "1" }});
    try expectVars("A=export\n", &.{.{ "A", "export" }});
    try expectVars("export A=1\nexport B=2\n", &.{ .{ "A", "1" }, .{ "B", "2" } });
}

test "a repeated key keeps the last value without leaking" {
    try expectVars("A=first\nA=second\n", &.{.{ "A", "second" }});
}

test "unterminated quotes are an error with a line number" {
    var diag: Diagnostics = .{};
    try testing.expectError(
        error.UnterminatedDoubleQuote,
        parse(testing.allocator, "A=1\nB=\"open\n", &diag),
    );
    try testing.expectEqual(@as(usize, 2), diag.line);

    var diag2: Diagnostics = .{};
    try testing.expectError(
        error.UnterminatedSingleQuote,
        parse(testing.allocator, "A='open\n", &diag2),
    );
    try testing.expectEqual(@as(usize, 1), diag2.line);
}

test "expansion of $VAR, ${VAR} and ${VAR:-default}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var source: env.Map = .empty;
    try source.set(a, "TEST_HOME", "/home/test");
    try source.set(a, "BLANK", "");

    var vars = try parseWithExpansion(a,
        \\PLAIN="$TEST_HOME/bin"
        \\BRACED="${TEST_HOME}/lib"
        \\MISSING="${NOPE:-fallback}"
        \\PRESENT="${TEST_HOME:-fallback}"
        \\BLANK_FALLS_BACK="${BLANK:-used}"
        \\NOT_A_REF="100$ and $ "
        \\
    , &source, null);

    try testing.expectEqualStrings("/home/test/bin", vars.get("PLAIN").?);
    try testing.expectEqualStrings("/home/test/lib", vars.get("BRACED").?);
    try testing.expectEqualStrings("fallback", vars.get("MISSING").?);
    try testing.expectEqualStrings("/home/test", vars.get("PRESENT").?);
    // Пустое значение равнозначно отсутствию и уступает умолчанию.
    try testing.expectEqualStrings("used", vars.get("BLANK_FALLS_BACK").?);
    try testing.expectEqualStrings("100$ and $ ", vars.get("NOT_A_REF").?);
}

test "without expansion a dollar sign is literal" {
    try expectVars("A=\"$TEST_HOME/bin\"\n", &.{.{ "A", "$TEST_HOME/bin" }});
}

test "empty input yields no variables" {
    try expectVars("", &.{});
    try expectVars("\n\n   \n\t\n", &.{});
    try expectVars("# only a comment\n", &.{});
}
