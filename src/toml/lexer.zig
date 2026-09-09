//! Лексер TOML 1.0 — подмножество, которого хватает для `envee.toml`.
//!
//! Заменяет `BurntSushi/toml` из Go-версии. Собственная реализация нужна не
//! из принципа: канонический хеш конфига считается по результату разбора, и
//! чужая библиотека диктовала бы его формат (см. ADR о хеше v2).
//!
//! Что НЕ поддерживается сознательно:
//!   - даты и время. В `envee.toml` их нет, а разбор офсетов и долей секунды
//!     стоит больше, чем даёт. Встретив дату, лексер возвращает
//!     `error.UnsupportedDateTime` с позицией, а не молча портит значение.
//!
//! Позиция (строка и столбец) есть у каждого токена: в Go-версии на месте
//! номера строки в ошибках парсинга стоял TODO, и пользователь получал
//! «failed to parse envee.toml» без указания места.
//!
//! Владение: лексер не выделяет память и не копирует вход. Токен — это срез
//! исходного текста; раскодирование escape-последовательностей делает
//! парсер, потому что только там есть аллокатор.

const std = @import("std");

pub const Kind = enum {
    /// Ключ без кавычек: буквы, цифры, `_`, `-`.
    bare_key,
    /// Строка в двойных кавычках. `text` — содержимое без кавычек, с
    /// неразобранными escape-последовательностями.
    string_basic,
    /// Строка в одинарных кавычках, буквальная.
    string_literal,
    /// `"""..."""`.
    string_multiline_basic,
    /// `'''...'''`.
    string_multiline_literal,
    integer,
    float,
    boolean,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    equals,
    dot,
    comma,
    /// Конец строки. Значим: он завершает пару ключ-значение.
    newline,
    eof,
};

pub const Token = struct {
    kind: Kind,
    /// Срез исходного текста. Для строк — содержимое без кавычек.
    text: []const u8,
    line: usize,
    column: usize,
};

pub const Error = error{
    UnterminatedString,
    UnsupportedDateTime,
    InvalidNumber,
    UnexpectedCharacter,
    InvalidEscape,
};

/// Где именно споткнулись. Отдельно от error set, который нагрузки не носит.
pub const Diagnostics = struct {
    line: usize = 0,
    column: usize = 0,
    /// Фрагмент, на котором споткнулись.
    text: []const u8 = "",
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    /// Смещение начала текущей строки — из него считается столбец.
    line_start: usize = 0,
    diag: ?*Diagnostics = null,

    pub fn init(src: []const u8, diag: ?*Diagnostics) Lexer {
        return .{ .src = src, .diag = diag };
    }

    fn column(l: Lexer, pos: usize) usize {
        return pos - l.line_start + 1;
    }

    fn fail(l: *Lexer, pos: usize, text: []const u8, e: Error) Error {
        if (l.diag) |d| d.* = .{ .line = l.line, .column = l.column(pos), .text = text };
        return e;
    }

    fn peek(l: Lexer, ahead: usize) ?u8 {
        return if (l.pos + ahead < l.src.len) l.src[l.pos + ahead] else null;
    }

    /// Следующий токен. По исчерпании входа бесконечно отдаёт `.eof`.
    pub fn next(l: *Lexer) Error!Token {
        l.skipSpaceAndComments();
        const start = l.pos;
        const col = l.column(start);

        if (l.pos >= l.src.len) {
            return .{ .kind = .eof, .text = "", .line = l.line, .column = col };
        }

        const c = l.src[l.pos];
        switch (c) {
            '\n' => {
                l.pos += 1;
                const tok: Token = .{ .kind = .newline, .text = "\n", .line = l.line, .column = col };
                l.line += 1;
                l.line_start = l.pos;
                return tok;
            },
            '[' => return l.single(.lbracket, col),
            ']' => return l.single(.rbracket, col),
            '{' => return l.single(.lbrace, col),
            '}' => return l.single(.rbrace, col),
            '=' => return l.single(.equals, col),
            '.' => return l.single(.dot, col),
            ',' => return l.single(.comma, col),
            '"' => return l.lexBasicString(col),
            '\'' => return l.lexLiteralString(col),
            else => {},
        }

        // Ветка выбирается по ПЕРВОМУ символу, и это принципиально.
        // Точка входит в число (3.14), но разделяет части составного ключа
        // (_.path). Один общий набор символов склеил бы `_.path` в один
        // токен, и директивы перестали бы разбираться.
        if (c >= '0' and c <= '9') return l.lexNumber(col);
        if ((c == '-' or c == '+') and isDigit(l.peek(1))) return l.lexNumber(col);
        if (isBareKeyChar(c)) return l.lexBareKey(col);
        return l.fail(start, l.src[start .. start + 1], error.UnexpectedCharacter);
    }

    fn single(l: *Lexer, kind: Kind, col: usize) Token {
        const start = l.pos;
        l.pos += 1;
        return .{ .kind = kind, .text = l.src[start..l.pos], .line = l.line, .column = col };
    }

    /// Пропускает пробелы, табы, `\r` и комментарии до конца строки.
    /// Перевод строки НЕ пропускается: он значимый токен.
    fn skipSpaceAndComments(l: *Lexer) void {
        while (l.pos < l.src.len) {
            switch (l.src[l.pos]) {
                ' ', '\t', '\r' => l.pos += 1,
                '#' => while (l.pos < l.src.len and l.src[l.pos] != '\n') {
                    l.pos += 1;
                },
                else => return,
            }
        }
    }

    fn lexBasicString(l: *Lexer, col: usize) Error!Token {
        const open = l.pos;
        if (l.peek(1) == '"' and l.peek(2) == '"') return l.lexMultiline(col, '"', .string_multiline_basic);

        l.pos += 1; // открывающая кавычка
        const start = l.pos;
        while (l.pos < l.src.len) {
            switch (l.src[l.pos]) {
                '\\' => {
                    // Экранированная кавычка не закрывает строку. Сама
                    // последовательность разбирается парсером.
                    l.pos += 2;
                    continue;
                },
                '"' => {
                    const text = l.src[start..l.pos];
                    l.pos += 1;
                    return .{ .kind = .string_basic, .text = text, .line = l.line, .column = col };
                },
                // Однострочная строка не может содержать перевод строки:
                // иначе незакрытая кавычка проглотила бы полфайла.
                '\n' => break,
                else => l.pos += 1,
            }
        }
        return l.fail(open, l.src[open..@min(l.pos, l.src.len)], error.UnterminatedString);
    }

    fn lexLiteralString(l: *Lexer, col: usize) Error!Token {
        const open = l.pos;
        if (l.peek(1) == '\'' and l.peek(2) == '\'') return l.lexMultiline(col, '\'', .string_multiline_literal);

        l.pos += 1;
        const start = l.pos;
        while (l.pos < l.src.len) : (l.pos += 1) {
            switch (l.src[l.pos]) {
                // В буквальной строке escape-последовательностей нет вовсе,
                // поэтому первая же кавычка её закрывает.
                '\'' => {
                    const text = l.src[start..l.pos];
                    l.pos += 1;
                    return .{ .kind = .string_literal, .text = text, .line = l.line, .column = col };
                },
                '\n' => break,
                else => {},
            }
        }
        return l.fail(open, l.src[open..@min(l.pos, l.src.len)], error.UnterminatedString);
    }

    fn lexMultiline(l: *Lexer, col: usize, quote: u8, kind: Kind) Error!Token {
        const open = l.pos;
        const open_line = l.line;
        // Начало строки тоже надо запомнить: сканируя многострочный литерал,
        // мы его двигаем, и без восстановления вычисление столбца в ошибке
        // ушло бы в минус (а usize этого не прощает).
        const open_line_start = l.line_start;
        l.pos += 3;
        // Перевод строки сразу после открывающих кавычек отбрасывается.
        if (l.pos < l.src.len and l.src[l.pos] == '\n') {
            l.pos += 1;
            l.line += 1;
            l.line_start = l.pos;
        }
        const start = l.pos;

        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\\' and kind == .string_multiline_basic) {
                l.pos += 2;
                continue;
            }
            if (c == '\n') {
                l.pos += 1;
                l.line += 1;
                l.line_start = l.pos;
                continue;
            }
            if (c == quote and l.peek(1) == quote and l.peek(2) == quote) {
                const text = l.src[start..l.pos];
                l.pos += 3;
                return .{ .kind = kind, .text = text, .line = open_line, .column = col };
            }
            l.pos += 1;
        }
        l.line = open_line;
        l.line_start = open_line_start;
        return l.fail(open, l.src[open..@min(open + 16, l.src.len)], error.UnterminatedString);
    }

    /// Ключ без кавычек: буквы, цифры, `_`, `-`. Точка сюда не входит.
    ///
    /// Литералы `true`, `false`, `inf` и `nan` тоже приходят сюда, и это
    /// не упущение: по спецификации TOML они же — допустимые имена ключей.
    /// Что перед нами, решает парсер, у которого есть контекст.
    fn lexBareKey(l: *Lexer, col: usize) Error!Token {
        const start = l.pos;
        while (l.pos < l.src.len and isBareKeyChar(l.src[l.pos])) l.pos += 1;
        return .{ .kind = .bare_key, .text = l.src[start..l.pos], .line = l.line, .column = col };
    }

    /// Число: целое, дробное, со знаком, с разделителями `_`, в любой из
    /// систем счисления TOML. Сюда же попадают даты — чтобы честно от них
    /// отказаться, а не разобрать как что-то другое.
    fn lexNumber(l: *Lexer, col: usize) Error!Token {
        const start = l.pos;
        if (l.pos < l.src.len and (l.src[l.pos] == '-' or l.src[l.pos] == '+')) l.pos += 1;
        while (l.pos < l.src.len and isNumberChar(l.src[l.pos])) l.pos += 1;
        const text = l.src[start..l.pos];

        // Дата или время — единственное, чего мы намеренно не умеем. Ошибка
        // с позицией лучше, чем молча разобранный мусор.
        if (looksLikeDateTime(text)) return l.fail(start, text, error.UnsupportedDateTime);

        const kind: Kind = if (isFloatText(text)) .float else .integer;
        return .{ .kind = kind, .text = text, .line = l.line, .column = col };
    }
};

fn isDigit(c: ?u8) bool {
    const ch = c orelse return false;
    return ch >= '0' and ch <= '9';
}

fn isBareKeyChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '-';
}

/// Символы, из которых состоит числовой литерал после первого. Буквы нужны
/// для 0x/0o/0b, показателя степени и inf/nan; двоеточие и дефис — только
/// чтобы распознать и отвергнуть дату.
fn isNumberChar(c: u8) bool {
    return isBareKeyChar(c) or c == '.' or c == ':' or c == '+';
}

fn isFloatText(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "inf") != null or std.mem.indexOf(u8, text, "nan") != null) return true;
    if (std.mem.indexOfScalar(u8, text, '.') != null) return true;
    // У шестнадцатеричных литералов `e` — это цифра, а не показатель степени.
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) return false;
    return std.mem.indexOfScalar(u8, text, 'e') != null or std.mem.indexOfScalar(u8, text, 'E') != null;
}

/// Дата (`2026-09-08`), время (`07:32:00`) или их сочетание.
fn looksLikeDateTime(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, ':') != null) return true;
    // Четыре цифры, дефис, цифра — это год-месяц, а не отрицательное число.
    if (text.len >= 6 and std.mem.indexOfScalar(u8, text, '-') == 4) {
        for (text[0..4]) |c| {
            if (c < '0' or c > '9') return false;
        }
        return text[5] >= '0' and text[5] <= '9';
    }
    return false;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Собирает все токены до eof.
fn lexAll(gpa: std.mem.Allocator, src: []const u8, diag: ?*Diagnostics) Error![]Token {
    var l = Lexer.init(src, diag);
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        const t = try l.next();
        out.append(gpa, t) catch return error.UnexpectedCharacter;
        if (t.kind == .eof) break;
    }
    return out.toOwnedSlice(gpa) catch error.UnexpectedCharacter;
}

fn expectKinds(src: []const u8, want: []const Kind) !void {
    const toks = try lexAll(testing.allocator, src, null);
    defer testing.allocator.free(toks);
    testing.expectEqual(want.len, toks.len) catch |err| {
        std.debug.print("source: {s}\ngot:", .{src});
        for (toks) |t| std.debug.print(" {s}({s})", .{ @tagName(t.kind), t.text });
        std.debug.print("\n", .{});
        return err;
    };
    for (want, toks) |w, t| {
        testing.expectEqual(w, t.kind) catch |err| {
            std.debug.print("source: {s}, token {s}({s})\n", .{ src, @tagName(t.kind), t.text });
            return err;
        };
    }
}

test "punctuation and structure" {
    try expectKinds("[env]", &.{ .lbracket, .bare_key, .rbracket, .eof });
    try expectKinds("a.b = 1", &.{ .bare_key, .dot, .bare_key, .equals, .integer, .eof });
    try expectKinds("{ a = 1, b = 2 }", &.{
        .lbrace,   .bare_key, .equals,  .integer, .comma,
        .bare_key, .equals,   .integer, .rbrace,  .eof,
    });
    // `[[` не отдельный токен: разбирать его как заголовок массива таблиц
    // или как вложенный массив решает парсер, у которого есть контекст.
    try expectKinds("[[a]]", &.{ .lbracket, .lbracket, .bare_key, .rbracket, .rbracket, .eof });
}

test "newlines are significant, spaces and comments are not" {
    try expectKinds("a = 1\nb = 2", &.{
        .bare_key, .equals, .integer, .newline,
        .bare_key, .equals, .integer, .eof,
    });
    try expectKinds("# only a comment", &.{.eof});
    try expectKinds("a = 1 # trailing\n", &.{ .bare_key, .equals, .integer, .newline, .eof });
    try expectKinds("  \t a\t=\t1  ", &.{ .bare_key, .equals, .integer, .eof });
    // CRLF: `\r` пропускается вместе с пробелами.
    try expectKinds("a = 1\r\nb = 2", &.{
        .bare_key, .equals, .integer, .newline,
        .bare_key, .equals, .integer, .eof,
    });
}

test "strings" {
    const toks = try lexAll(testing.allocator,
        \\a = "basic"
        \\b = 'literal'
        \\c = "with \"escape\" inside"
        \\d = 'no \n escape'
    , null);
    defer testing.allocator.free(toks);

    try testing.expectEqual(Kind.string_basic, toks[2].kind);
    try testing.expectEqualStrings("basic", toks[2].text);
    try testing.expectEqual(Kind.string_literal, toks[6].kind);
    try testing.expectEqualStrings("literal", toks[6].text);
    // Экранированная кавычка не закрывает строку; сам escape остаётся
    // неразобранным — им займётся парсер.
    try testing.expectEqual(Kind.string_basic, toks[10].kind);
    try testing.expectEqualStrings("with \\\"escape\\\" inside", toks[10].text);
    try testing.expectEqualStrings("no \\n escape", toks[14].text);
}

test "multiline strings" {
    const toks = try lexAll(testing.allocator,
        \\a = """
        \\line1
        \\line2"""
        \\b = '''raw
        \\text'''
    , null);
    defer testing.allocator.free(toks);

    try testing.expectEqual(Kind.string_multiline_basic, toks[2].kind);
    // Перевод строки сразу после открывающих кавычек отбрасывается.
    try testing.expectEqualStrings("line1\nline2", toks[2].text);
    try testing.expectEqual(Kind.string_multiline_literal, toks[6].kind);
    try testing.expectEqualStrings("raw\ntext", toks[6].text);
}

test "numbers" {
    const cases = [_]struct { src: []const u8, kind: Kind }{
        .{ .src = "1", .kind = .integer },
        .{ .src = "5432", .kind = .integer },
        .{ .src = "-17", .kind = .integer },
        .{ .src = "+17", .kind = .integer },
        .{ .src = "1_000_000", .kind = .integer },
        .{ .src = "0xff", .kind = .integer },
        .{ .src = "0o755", .kind = .integer },
        .{ .src = "0b1010", .kind = .integer },
        .{ .src = "3.14", .kind = .float },
        .{ .src = "-0.5", .kind = .float },
        .{ .src = "1e10", .kind = .float },
        .{ .src = "1E-4", .kind = .float },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(testing.allocator, "k = {s}", .{c.src});
        defer testing.allocator.free(src);
        const toks = try lexAll(testing.allocator, src, null);
        defer testing.allocator.free(toks);
        testing.expectEqual(c.kind, toks[2].kind) catch |err| {
            std.debug.print("{s} lexed as {s}\n", .{ c.src, @tagName(toks[2].kind) });
            return err;
        };
        try testing.expectEqualStrings(c.src, toks[2].text);
    }
}

// true, false, inf и nan приходят как bare_key, и это не упущение: по
// спецификации TOML это же — допустимые имена ключей. Различить значение и
// ключ может только парсер, у которого есть контекст.
test "word-shaped literals stay bare keys for the parser to resolve" {
    for ([_][]const u8{ "true", "false", "inf", "nan" }) |word| {
        const src = try std.fmt.allocPrint(testing.allocator, "k = {s}", .{word});
        defer testing.allocator.free(src);
        const toks = try lexAll(testing.allocator, src, null);
        defer testing.allocator.free(toks);
        try testing.expectEqual(Kind.bare_key, toks[2].kind);
        try testing.expectEqualStrings(word, toks[2].text);
    }
    // И они же работают слева от знака равенства.
    try expectKinds("true = 1", &.{ .bare_key, .equals, .integer, .eof });
}

// Знак перед числом — часть числа, но дефис внутри слова — часть ключа.
test "signs belong to numbers, dashes belong to keys" {
    try expectKinds("k = -17", &.{ .bare_key, .equals, .integer, .eof });
    try expectKinds("a-b = 1", &.{ .bare_key, .equals, .integer, .eof });
}

// Составной ключ обязан распадаться на части: без этого директивы вида
// `_.path` склеивались бы в один токен и переставали разбираться.
test "dotted keys split, decimal points do not" {
    try expectKinds("_.path = 1", &.{ .bare_key, .dot, .bare_key, .equals, .integer, .eof });
    try expectKinds("a.b.c = 1", &.{ .bare_key, .dot, .bare_key, .dot, .bare_key, .equals, .integer, .eof });
    try expectKinds("k = 3.14", &.{ .bare_key, .equals, .float, .eof });
}

test "bare keys allow digits, dashes and underscores" {
    const toks = try lexAll(testing.allocator, "key-name_2 = 1", null);
    defer testing.allocator.free(toks);
    try testing.expectEqual(Kind.bare_key, toks[0].kind);
    try testing.expectEqualStrings("key-name_2", toks[0].text);
}

test "positions are tracked for every token" {
    const toks = try lexAll(testing.allocator, "a = 1\n\n  bb = 2", null);
    defer testing.allocator.free(toks);

    try testing.expectEqual(@as(usize, 1), toks[0].line);
    try testing.expectEqual(@as(usize, 1), toks[0].column);
    // `bb` — третья строка, третий столбец.
    const bb = toks[5];
    try testing.expectEqualStrings("bb", bb.text);
    try testing.expectEqual(@as(usize, 3), bb.line);
    try testing.expectEqual(@as(usize, 3), bb.column);
}

// Даты — единственное, чего лексер намеренно не умеет. Молча разобрать их
// как что-то другое было бы хуже, чем честно отказаться.
test "dates and times are refused with a position" {
    const cases = [_][]const u8{
        "d = 2026-09-08",
        "d = 07:32:00",
        "d = 2026-09-08T07:32:00Z",
    };
    for (cases) |src| {
        var diag: Diagnostics = .{};
        try testing.expectError(error.UnsupportedDateTime, lexAll(testing.allocator, src, &diag));
        try testing.expectEqual(@as(usize, 1), diag.line);
        try testing.expectEqual(@as(usize, 5), diag.column);
    }
    // А вот отрицательное число датой не является.
    try expectKinds("d = -17", &.{ .bare_key, .equals, .integer, .eof });
}

test "unterminated strings are refused with a position" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.UnterminatedString, lexAll(testing.allocator, "a = \"open\nb = 1", &diag));
    try testing.expectEqual(@as(usize, 1), diag.line);

    diag = .{};
    try testing.expectError(error.UnterminatedString, lexAll(testing.allocator, "a = 'open", &diag));

    diag = .{};
    try testing.expectError(error.UnterminatedString, lexAll(testing.allocator, "a = \"\"\"open\nstill open", &diag));
    // Многострочная строка сообщает о СВОЁМ начале, а не о конце файла.
    try testing.expectEqual(@as(usize, 1), diag.line);
}

test "an unexpected character is refused with a position" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.UnexpectedCharacter, lexAll(testing.allocator, "a = 1\n?\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expectEqual(@as(usize, 1), diag.column);
}

// Настоящие файлы из examples/ читаются с диска, а не копируются в тест:
// копия рано или поздно разойдётся с оригиналом и перестанет что-либо
// проверять.
test "every example config in the repository lexes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var found: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".toml")) continue;

        const src = try dir.readFileAlloc(io, entry.path, a, .unlimited);
        var diag: Diagnostics = .{};
        const toks = lexAll(a, src, &diag) catch |err| {
            std.debug.print("examples/{s}:{d}:{d}: {s} at \"{s}\"\n", .{
                entry.path, diag.line, diag.column, @errorName(err), diag.text,
            });
            return err;
        };
        try testing.expect(toks.len > 1);
        found += 1;
    }
    // Если примеров вдруг не осталось, тест обязан упасть, а не тихо пройти.
    try testing.expect(found >= 4);
}

test "a real envee.toml lexes without error" {
    const src =
        \\schema = "envee/v1"
        \\profile = "dev"
        \\
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\PORT = 5432
        \\DEBUG = true
        \\ALLOWED_ORIGINS = ["http://localhost:3000", "https://app.example.com"]
        \\API_KEY = { value = "dev-key", redact = true, required = false }
        \\_.path = ["./bin", "{{config_root}}/node_modules/.bin"]
        \\
        \\[profiles.prod]
        \\required = ["DATABASE_URL"]
    ;
    const toks = try lexAll(testing.allocator, src, null);
    defer testing.allocator.free(toks);
    try testing.expect(toks.len > 50);
    try testing.expectEqual(Kind.eof, toks[toks.len - 1].kind);

    // Двоеточие внутри строки не должно приниматься за время.
    var found_url = false;
    for (toks) |t| {
        if (t.kind == .string_basic and std.mem.indexOf(u8, t.text, "localhost:3000") != null) found_url = true;
    }
    try testing.expect(found_url);
}
