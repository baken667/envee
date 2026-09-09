//! Парсер TOML поверх лексера из соседнего файла.
//!
//! Поддерживается всё, что встречается в `envee.toml` и в тестах Go-версии:
//! заголовки таблиц `[a.b.c]`, массивы таблиц `[[a]]`, составные ключи
//! `_.path = ...`, inline-таблицы, массивы (в том числе многострочные и с
//! запятой в конце), строки всех четырёх видов, числа во всех системах
//! счисления.
//!
//! Не поддерживаются даты и время: лексер отвергает их с указанием места.
//!
//! Владение: дерево целиком выделяется из переданного аллокатора и никогда
//! не освобождается по частям — передавать сюда следует АРЕНУ. Причина в
//! value.zig, в шапке файла.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lexer = @import("lexer.zig");
const value = @import("value.zig");

const Lexer = lexer.Lexer;
const Token = lexer.Token;
const Kind = lexer.Kind;
pub const Value = value.Value;
pub const Table = value.Table;

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    DuplicateKey,
    /// Попытка дописать в таблицу, объявленную как inline `{ ... }`.
    InlineTableExtended,
    /// Ключ занят значением, которое не является таблицей.
    NotATable,
    InvalidNumber,
    InvalidEscape,
    InvalidValue,
} || lexer.Error || Allocator.Error;

/// Место и обстоятельство ошибки. Go-версия на этом месте имела TODO, и
/// пользователь получал «failed to parse envee.toml» без указания строки.
pub const Diagnostics = struct {
    line: usize = 0,
    column: usize = 0,
    /// Фрагмент, на котором споткнулись.
    text: []const u8 = "",
    /// Что именно ожидалось.
    detail: []const u8 = "",
};

/// Разбирает документ TOML целиком.
pub fn parse(arena: Allocator, src: []const u8, diag: ?*Diagnostics) Error!*Table {
    var lex_diag: lexer.Diagnostics = .{};
    var p: Parser = .{
        .arena = arena,
        .lex = Lexer.init(src, &lex_diag),
        .lex_diag = &lex_diag,
        .diag = diag,
        .root = undefined,
        .current = undefined,
        .tok = undefined,
    };
    p.root = try Table.create(arena);
    p.root.explicit = true;
    p.current = p.root;

    try p.advance();
    try p.parseDocument();
    return p.root;
}

const Parser = struct {
    arena: Allocator,
    lex: Lexer,
    lex_diag: *lexer.Diagnostics,
    diag: ?*Diagnostics,
    root: *Table,
    /// Таблица, в которую попадают пары ключ-значение вне заголовков.
    current: *Table,
    tok: Token,

    /// Берёт следующий токен, попутно перенося позицию из диагностики
    /// лексера в свою: пользователю нужно одно сообщение, а не два разных
    /// формата. Подъём делается здесь, а не у вызывающего, потому что
    /// лексер может споткнуться на любом из десятка мест разбора.
    fn advance(p: *Parser) Error!void {
        p.tok = p.lex.next() catch |err| {
            if (p.diag) |d| d.* = .{
                .line = p.lex_diag.line,
                .column = p.lex_diag.column,
                .text = p.lex_diag.text,
                .detail = @errorName(err),
            };
            return err;
        };
    }

    fn fail(p: *Parser, detail: []const u8, e: Error) Error {
        if (p.diag) |d| d.* = .{
            .line = p.tok.line,
            .column = p.tok.column,
            .text = p.tok.text,
            .detail = detail,
        };
        return e;
    }

    fn skipNewlines(p: *Parser) Error!void {
        while (p.tok.kind == .newline) try p.advance();
    }

    fn expect(p: *Parser, kind: Kind, detail: []const u8) Error!Token {
        if (p.tok.kind != kind) return p.fail(detail, error.UnexpectedToken);
        const t = p.tok;
        try p.advance();
        return t;
    }

    fn parseDocument(p: *Parser) Error!void {
        while (true) {
            try p.skipNewlines();
            switch (p.tok.kind) {
                .eof => return,
                .lbracket => try p.parseHeader(),
                else => {
                    try p.parseKeyValue(p.current);
                    // Пара обязана заканчиваться концом строки: без этого
                    // `a = 1 b = 2` разобралось бы молча.
                    switch (p.tok.kind) {
                        .newline, .eof => {},
                        else => return p.fail("expected a newline after the value", error.UnexpectedToken),
                    }
                },
            }
        }
    }

    /// `[a.b]` или `[[a.b]]`.
    fn parseHeader(p: *Parser) Error!void {
        try p.advance(); // '['
        const is_array = p.tok.kind == .lbracket;
        if (is_array) try p.advance();

        const path = try p.parseKeyPath();
        if (path.len == 0) return p.fail("expected a table name", error.UnexpectedToken);

        _ = try p.expect(.rbracket, "expected ']'");
        if (is_array) _ = try p.expect(.rbracket, "expected ']]'");

        p.current = if (is_array)
            try p.appendArrayTable(path)
        else
            try p.declareTable(path);

        switch (p.tok.kind) {
            .newline, .eof => {},
            else => return p.fail("expected a newline after the table header", error.UnexpectedToken),
        }
    }

    /// Объявляет таблицу заголовком `[a.b]`, создавая промежуточные.
    fn declareTable(p: *Parser, path: []const []const u8) Error!*Table {
        var t = p.root;
        for (path, 0..) |part, i| {
            const last = i == path.len - 1;
            t = try p.descend(t, part, last);
            if (last) {
                // Повторное объявление одной и той же таблицы TOML
                // запрещает: это почти всегда опечатка или склейка двух
                // конфигов, и молча слить их — потерять половину.
                if (t.explicit) return p.fail("this table is already defined", error.DuplicateKey);
                t.explicit = true;
            }
        }
        return t;
    }

    /// Добавляет элемент в массив таблиц `[[a.b]]`.
    fn appendArrayTable(p: *Parser, path: []const []const u8) Error!*Table {
        var parent = p.root;
        for (path[0 .. path.len - 1]) |part| parent = try p.descend(parent, part, false);

        const key = path[path.len - 1];
        const fresh = try Table.create(p.arena);
        fresh.explicit = true;

        if (parent.map.getPtr(key)) |existing| {
            const arr = existing.asArray() orelse
                return p.fail("this key is not an array of tables", error.NotATable);
            const grown = try p.arena.alloc(Value, arr.len + 1);
            @memcpy(grown[0..arr.len], arr);
            grown[arr.len] = .{ .table = fresh };
            existing.* = .{ .array = grown };
        } else {
            const items = try p.arena.alloc(Value, 1);
            items[0] = .{ .table = fresh };
            try parent.put(p.arena, key, .{ .array = items });
        }
        return fresh;
    }

    /// Спускается на один уровень, создавая таблицу при необходимости.
    ///
    /// Если по пути лежит массив таблиц, продолжаем в его ПОСЛЕДНЕМ элементе:
    /// так `[[a]]` с последующим `[a.b]` дописывает в текущий элемент.
    fn descend(p: *Parser, t: *Table, key: []const u8, final: bool) Error!*Table {
        if (t.map.get(key)) |existing| {
            switch (existing) {
                .table => |sub| {
                    if (sub.inline_table) {
                        return p.fail("an inline table cannot be extended", error.InlineTableExtended);
                    }
                    return sub;
                },
                .array => |items| {
                    if (final or items.len == 0 or items[items.len - 1] != .table) {
                        return p.fail("this key is not a table", error.NotATable);
                    }
                    return items[items.len - 1].table;
                },
                else => return p.fail("this key is not a table", error.NotATable),
            }
        }
        const fresh = try Table.create(p.arena);
        try t.put(p.arena, key, .{ .table = fresh });
        return fresh;
    }

    /// `key = value` или `a.b.c = value`.
    fn parseKeyValue(p: *Parser, into: *Table) Error!void {
        const path = try p.parseKeyPath();
        if (path.len == 0) return p.fail("expected a key", error.UnexpectedToken);
        _ = try p.expect(.equals, "expected '='");

        const v = try p.parseValue();

        var t = into;
        for (path[0 .. path.len - 1]) |part| t = try p.descend(t, part, false);

        const key = path[path.len - 1];
        if (t.map.contains(key)) return p.fail("this key is already defined", error.DuplicateKey);
        try t.put(p.arena, key, v);
    }

    /// Составной ключ: `a`, `a.b`, `"a.b".c`.
    fn parseKeyPath(p: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            const part = switch (p.tok.kind) {
                .bare_key => p.tok.text,
                .integer => p.tok.text, // ключ вида `2` разрешён спецификацией
                .string_basic => try p.decodeBasic(p.tok.text, false),
                .string_literal => p.tok.text,
                else => break,
            };
            try parts.append(p.arena, part);
            try p.advance();
            if (p.tok.kind != .dot) break;
            try p.advance();
        }
        return parts.toOwnedSlice(p.arena);
    }

    fn parseValue(p: *Parser) Error!Value {
        switch (p.tok.kind) {
            .string_basic => {
                const s = try p.decodeBasic(p.tok.text, false);
                try p.advance();
                return .{ .string = s };
            },
            .string_multiline_basic => {
                const s = try p.decodeBasic(p.tok.text, true);
                try p.advance();
                return .{ .string = s };
            },
            .string_literal => {
                const s = p.tok.text;
                try p.advance();
                return .{ .string = s };
            },
            .string_multiline_literal => {
                const s = try normalizeNewlines(p.arena, p.tok.text);
                try p.advance();
                return .{ .string = s };
            },
            .integer => {
                const text = p.tok.text;
                const n = std.fmt.parseInt(i64, text, 0) catch
                    return p.fail("not a valid integer", error.InvalidNumber);
                try p.advance();
                return .{ .integer = n };
            },
            .float => {
                const text = p.tok.text;
                const f = std.fmt.parseFloat(f64, text) catch
                    return p.fail("not a valid float", error.InvalidNumber);
                try p.advance();
                return .{ .float = f };
            },
            .bare_key => {
                // Лексер не различает значение и имя ключа, потому что по
                // спецификации `true` и `inf` допустимы и там, и там.
                // Контекст есть только здесь.
                const text = p.tok.text;
                try p.advance();
                if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, text, "inf")) return .{ .float = std.math.inf(f64) };
                if (std.mem.eql(u8, text, "nan")) return .{ .float = std.math.nan(f64) };
                return p.fail("expected a value", error.InvalidValue);
            },
            .lbracket => return p.parseArray(),
            .lbrace => return p.parseInlineTable(),
            .eof => return p.fail("expected a value", error.UnexpectedEof),
            else => return p.fail("expected a value", error.UnexpectedToken),
        }
    }

    fn parseArray(p: *Parser) Error!Value {
        try p.advance(); // '['
        var items: std.ArrayList(Value) = .empty;

        while (true) {
            try p.skipNewlines(); // массив может занимать несколько строк
            if (p.tok.kind == .rbracket) {
                try p.advance();
                break;
            }
            if (p.tok.kind == .eof) return p.fail("unterminated array", error.UnexpectedEof);

            try items.append(p.arena, try p.parseValue());

            try p.skipNewlines();
            switch (p.tok.kind) {
                .comma => try p.advance(),
                .rbracket => {
                    try p.advance();
                    break;
                },
                .eof => return p.fail("unterminated array", error.UnexpectedEof),
                else => return p.fail("expected ',' or ']'", error.UnexpectedToken),
            }
        }
        return .{ .array = try items.toOwnedSlice(p.arena) };
    }

    fn parseInlineTable(p: *Parser) Error!Value {
        try p.advance(); // '{'
        const t = try Table.create(p.arena);
        t.inline_table = true;

        // Пустая inline-таблица — законное значение.
        if (p.tok.kind == .rbrace) {
            try p.advance();
            return .{ .table = t };
        }

        while (true) {
            try p.parseKeyValue(t);
            switch (p.tok.kind) {
                .comma => {
                    try p.advance();
                    // Запятая в конце inline-таблицы спецификацией запрещена,
                    // но встречается; принимаем молча.
                    if (p.tok.kind == .rbrace) {
                        try p.advance();
                        return .{ .table = t };
                    }
                },
                .rbrace => {
                    try p.advance();
                    return .{ .table = t };
                },
                .eof => return p.fail("unterminated inline table", error.UnexpectedEof),
                else => return p.fail("expected ',' or '}'", error.UnexpectedToken),
            }
        }
    }

    /// Раскрывает escape-последовательности строки в двойных кавычках.
    fn decodeBasic(p: *Parser, raw: []const u8, multiline: bool) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            return if (multiline) normalizeNewlines(p.arena, raw) else raw;
        }

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') {
                i += 1; // CRLF приводим к LF, см. normalizeNewlines
                continue;
            }
            if (c != '\\') {
                try out.append(p.arena, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len) return p.fail("a string ends with a backslash", error.InvalidEscape);
            const e = raw[i];
            i += 1;
            switch (e) {
                'b' => try out.append(p.arena, 0x08),
                't' => try out.append(p.arena, '\t'),
                'n' => try out.append(p.arena, '\n'),
                'f' => try out.append(p.arena, 0x0c),
                'r' => try out.append(p.arena, '\r'),
                '"' => try out.append(p.arena, '"'),
                '\\' => try out.append(p.arena, '\\'),
                'u', 'U' => {
                    const width: usize = if (e == 'u') 4 else 8;
                    if (i + width > raw.len) return p.fail("a truncated \\u escape", error.InvalidEscape);
                    const cp = std.fmt.parseInt(u21, raw[i .. i + width], 16) catch
                        return p.fail("a malformed \\u escape", error.InvalidEscape);
                    i += width;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch
                        return p.fail("a \\u escape outside Unicode", error.InvalidEscape);
                    try out.appendSlice(p.arena, buf[0..n]);
                },
                '\n', ' ', '\t', '\r' => {
                    if (!multiline) return p.fail("an unknown escape sequence", error.InvalidEscape);
                    // Обратный слэш в конце строки склеивает строки, съедая
                    // перевод и весь последующий отступ.
                    i -= 1;
                    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or
                        raw[i] == '\n' or raw[i] == '\r')) i += 1;
                },
                else => return p.fail("an unknown escape sequence", error.InvalidEscape),
            }
        }
        return out.toOwnedSlice(p.arena);
    }
};

/// Приводит CRLF к LF. Файл, выгруженный на Windows, обязан давать тот же
/// разобранный текст и, как следствие, тот же канонический хеш.
fn normalizeNewlines(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\r') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') continue;
        try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn parseTest(arena: Allocator, src: []const u8) Error!*Table {
    return parse(arena, src, null);
}

test "scalars of every type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\s = "text"
        \\l = 'literal'
        \\i = 5432
        \\neg = -17
        \\hex = 0xff
        \\oct = 0o755
        \\bin = 0b1010
        \\sep = 1_000_000
        \\f = 3.14
        \\e = 1e3
        \\yes = true
        \\no = false
    );
    try testing.expectEqualStrings("text", t.get("s").?.asString().?);
    try testing.expectEqualStrings("literal", t.get("l").?.asString().?);
    try testing.expectEqual(@as(i64, 5432), t.get("i").?.asInt().?);
    try testing.expectEqual(@as(i64, -17), t.get("neg").?.asInt().?);
    try testing.expectEqual(@as(i64, 255), t.get("hex").?.asInt().?);
    try testing.expectEqual(@as(i64, 493), t.get("oct").?.asInt().?);
    try testing.expectEqual(@as(i64, 10), t.get("bin").?.asInt().?);
    try testing.expectEqual(@as(i64, 1000000), t.get("sep").?.asInt().?);
    try testing.expectEqual(@as(f64, 3.14), t.get("f").?.asFloat().?);
    try testing.expectEqual(@as(f64, 1000), t.get("e").?.asFloat().?);
    try testing.expectEqual(true, t.get("yes").?.asBool().?);
    try testing.expectEqual(false, t.get("no").?.asBool().?);
}

test "escape sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\nl = "a\nb"
        \\tab = "a\tb"
        \\quote = "say \"hi\""
        \\back = "a\\b"
        \\uni = "Aé"
        \\wide = "\U0001F389"
        \\raw = 'no \n escape'
    );
    try testing.expectEqualStrings("a\nb", t.get("nl").?.asString().?);
    try testing.expectEqualStrings("a\tb", t.get("tab").?.asString().?);
    try testing.expectEqualStrings("say \"hi\"", t.get("quote").?.asString().?);
    try testing.expectEqualStrings("a\\b", t.get("back").?.asString().?);
    try testing.expectEqualStrings("Aé", t.get("uni").?.asString().?);
    try testing.expectEqualStrings("🎉", t.get("wide").?.asString().?);
    // В буквальной строке escape-последовательностей нет вовсе.
    try testing.expectEqualStrings("no \\n escape", t.get("raw").?.asString().?);
}

test "multiline strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\a = """
        \\line1
        \\line2"""
        \\b = '''raw
        \\text'''
        \\c = """joined \
        \\   continues"""
    );
    try testing.expectEqualStrings("line1\nline2", t.get("a").?.asString().?);
    try testing.expectEqualStrings("raw\ntext", t.get("b").?.asString().?);
    // Обратный слэш в конце строки съедает перевод и отступ следующей.
    try testing.expectEqualStrings("joined continues", t.get("c").?.asString().?);
}

test "arrays, including multiline and trailing commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\flat = ["a", "b"]
        \\empty = []
        \\nums = [1, 2, 3]
        \\multi = [
        \\  "one",
        \\  "two",
        \\]
        \\nested = [[1, 2], [3]]
    );
    try testing.expectEqual(@as(usize, 2), t.get("flat").?.asArray().?.len);
    try testing.expectEqual(@as(usize, 0), t.get("empty").?.asArray().?.len);
    try testing.expectEqual(@as(i64, 2), t.get("nums").?.asArray().?[1].asInt().?);
    const multi = t.get("multi").?.asArray().?;
    try testing.expectEqual(@as(usize, 2), multi.len);
    try testing.expectEqualStrings("two", multi[1].asString().?);
    // Вложенный массив — не заголовок массива таблиц; их различает контекст.
    const nested = t.get("nested").?.asArray().?;
    try testing.expectEqual(@as(usize, 2), nested.len);
    try testing.expectEqual(@as(usize, 2), nested[0].asArray().?.len);
}

test "table headers, nested and dotted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\top = 1
        \\
        \\[env]
        \\KEY = "value"
        \\
        \\[profiles.dev.env]
        \\DEBUG = true
        \\
        \\[env._.secret.DB_PASSWORD]
        \\source = "vault"
    );
    try testing.expectEqual(@as(i64, 1), t.get("top").?.asInt().?);
    try testing.expectEqualStrings("value", t.getPath("env.KEY").?.asString().?);
    try testing.expectEqual(true, t.getPath("profiles.dev.env.DEBUG").?.asBool().?);
    try testing.expectEqualStrings("vault", t.getPath("env._.secret.DB_PASSWORD.source").?.asString().?);
}

// Составной ключ — это то, чем записаны директивы: `_.path = [...]`.
test "dotted keys create nested tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\[env]
        \\_.path = ["./bin"]
        \\_.file = ".env"
        \\a.b.c = 1
    );
    try testing.expectEqual(@as(usize, 1), t.getPath("env._.path").?.asArray().?.len);
    try testing.expectEqualStrings(".env", t.getPath("env._.file").?.asString().?);
    try testing.expectEqual(@as(i64, 1), t.getPath("env.a.b.c").?.asInt().?);
}

test "inline tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\simple = { value = "x", redact = true }
        \\empty = {}
        \\[env]
        \\_.file = [ { path = ".env", required = false }, { path = ".env.local" } ]
    );
    try testing.expectEqualStrings("x", t.getPath("simple.value").?.asString().?);
    try testing.expectEqual(true, t.getPath("simple.redact").?.asBool().?);
    try testing.expectEqual(@as(usize, 0), t.get("empty").?.asTable().?.count());

    const files = t.getPath("env._.file").?.asArray().?;
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings(".env", files[0].asTable().?.get("path").?.asString().?);
    try testing.expectEqual(false, files[0].asTable().?.get("required").?.asBool().?);
}

test "arrays of tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\[[items]]
        \\name = "first"
        \\
        \\[[items]]
        \\name = "second"
        \\
        \\[[items]]
        \\name = "third"
    );
    const items = t.get("items").?.asArray().?;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("first", items[0].asTable().?.get("name").?.asString().?);
    try testing.expectEqualStrings("third", items[2].asTable().?.get("name").?.asString().?);
}

test "quoted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\"quoted key" = 1
        \\'literal key' = 2
        \\"a.b" = 3
        \\[t]
        \\"x" = 4
    );
    try testing.expectEqual(@as(i64, 1), t.get("quoted key").?.asInt().?);
    try testing.expectEqual(@as(i64, 2), t.get("literal key").?.asInt().?);
    // Ключ с точкой внутри кавычек — один ключ, а не путь.
    try testing.expectEqual(@as(i64, 3), t.get("a.b").?.asInt().?);
    try testing.expectEqual(@as(i64, 4), t.getPath("t.x").?.asInt().?);
}

// `true` и `inf` — законные имена ключей, и парсер обязан различать их по
// месту, а не по написанию.
test "word-shaped literals work as both keys and values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\true = "a key named true"
        \\value = true
        \\inf = 1
        \\big = inf
    );
    try testing.expectEqualStrings("a key named true", t.get("true").?.asString().?);
    try testing.expectEqual(true, t.get("value").?.asBool().?);
    try testing.expectEqual(@as(i64, 1), t.get("inf").?.asInt().?);
    try testing.expect(std.math.isInf(t.get("big").?.asFloat().?));
}

test "comments and blank lines are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try parseTest(a,
        \\# leading comment
        \\
        \\a = 1  # trailing comment
        \\
        \\# another
        \\[t]  # after a header
        \\b = 2
    );
    try testing.expectEqual(@as(i64, 1), t.get("a").?.asInt().?);
    try testing.expectEqual(@as(i64, 2), t.getPath("t.b").?.asInt().?);
    try testing.expectEqual(@as(usize, 2), t.count());
}

test "an empty document parses to an empty table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try parseTest(a, "")).count());
    try testing.expectEqual(@as(usize, 0), (try parseTest(a, "\n\n# only a comment\n")).count());
}

test "duplicates are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(error.DuplicateKey, parse(a, "a = 1\na = 2\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);

    // Повторное объявление таблицы — почти всегда склейка двух конфигов;
    // молча слить их значило бы потерять половину.
    try testing.expectError(error.DuplicateKey, parse(a, "[t]\na = 1\n[t]\nb = 2\n", &diag));

    // Ключ, занятый скаляром, не может стать таблицей.
    try testing.expectError(error.NotATable, parse(a, "a = 1\n[a]\nb = 2\n", &diag));

    // Inline-таблицу спецификация запрещает дополнять позже.
    try testing.expectError(error.InlineTableExtended, parse(a, "a = { b = 1 }\n[a.c]\nd = 2\n", &diag));
}

test "syntax errors carry a position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { src: []const u8, err: anyerror, line: usize }{
        .{ .src = "a = \n", .err = error.UnexpectedToken, .line = 1 },
        .{ .src = "a 1\n", .err = error.UnexpectedToken, .line = 1 },
        .{ .src = "a = 1\nb = [1, 2\n", .err = error.UnexpectedEof, .line = 3 },
        .{ .src = "a = 1\n[t\n", .err = error.UnexpectedToken, .line = 2 },
        // Inline-таблица обязана уместиться в одну строку: перевод строки
        // внутри неё — ошибка по спецификации, и сообщить о ней надо на
        // самом переводе, а не в конце файла.
        .{ .src = "x = 1\ny = { a = 1\n", .err = error.UnexpectedToken, .line = 2 },
        .{ .src = "a = \"bad \\q escape\"\n", .err = error.InvalidEscape, .line = 1 },
        // Ошибка лексера тоже обязана прийти с местом.
        .{ .src = "a = 1\nd = 2026-09-08\n", .err = error.UnsupportedDateTime, .line = 2 },
        .{ .src = "a = 1\nb = \"unterminated\n", .err = error.UnterminatedString, .line = 2 },
    };
    for (cases) |c| {
        var diag: Diagnostics = .{};
        testing.expectError(c.err, parse(a, c.src, &diag)) catch |err| {
            std.debug.print("source: {s}\n", .{c.src});
            return err;
        };
        testing.expectEqual(c.line, diag.line) catch |err| {
            std.debug.print("source: {s} reported line {d}, detail {s}\n", .{ c.src, diag.line, diag.detail });
            return err;
        };
    }
}

test "two values on one line are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnexpectedToken, parse(a, "a = 1 b = 2\n", null));
}

// CRLF не должен менять ни разобранный текст, ни канонический хеш: иначе
// один и тот же конфиг требовал бы повторного одобрения после выгрузки на
// другой платформе.
test "CRLF parses identically to LF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lf = "a = 1\n[t]\nb = \"x\"\nm = \"\"\"one\ntwo\"\"\"\n";
    const crlf = "a = 1\r\n[t]\r\nb = \"x\"\r\nm = \"\"\"one\r\ntwo\"\"\"\r\n";

    const one = try parseTest(a, lf);
    const other = try parseTest(a, crlf);
    try testing.expectEqualStrings("one\ntwo", other.getPath("t.m").?.asString().?);
    try testing.expectEqualStrings("one\ntwo", one.getPath("t.m").?.asString().?);
    try testing.expectEqualStrings(
        try value.canonicalHash(a, one),
        try value.canonicalHash(a, other),
    );
}

// Формат, комментарии, стиль кавычек и порядок ключей на хеш не влияют —
// иначе переформатирование конфига требовало бы повторного одобрения.
test "formatting does not change the hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try parseTest(a, "b = 2\na = \"x\"\n[t]\nk = true\n");
    const dressed = try parseTest(a,
        \\# a comment
        \\
        \\a   =   'x'
        \\b=2
        \\
        \\[t]
        \\k = true   # trailing
    );
    try testing.expectEqualStrings(
        try value.canonicalHash(a, plain),
        try value.canonicalHash(a, dressed),
    );

    // А смысловое отличие обязано хеш поменять.
    const changed = try parseTest(a, "b = 3\na = \"x\"\n[t]\nk = true\n");
    try testing.expect(!std.mem.eql(u8, try value.canonicalHash(a, plain), try value.canonicalHash(a, changed)));
}

test "every example config in the repository parses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var dir = std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var found: usize = 0;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".toml")) continue;

        const src = try dir.readFileAlloc(io, entry.path, a, .unlimited);
        var diag: Diagnostics = .{};
        const t = parse(a, src, &diag) catch |err| {
            std.debug.print("examples/{s}:{d}:{d}: {s} ({s}) at \"{s}\"\n", .{
                entry.path, diag.line, diag.column, @errorName(err), diag.detail, diag.text,
            });
            return err;
        };
        // Каждый пример объявляет схему — заодно проверяем, что разбор
        // добрался до содержимого, а не вернул пустое дерево.
        try testing.expect(t.get("schema") != null or t.count() > 0);
        found += 1;
    }
    try testing.expect(found >= 4);
}
