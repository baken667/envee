//! Дерево разобранного TOML и его каноническое представление.
//!
//! Владение: всё дерево выделяется из ОДНОГО аллокатора, и освобождается
//! оно целиком. Отдельного `deinit` здесь нет намеренно: строки в дереве
//! частью нарезаны из исходного текста, частью собраны заново (там, где были
//! escape-последовательности), и обходчик не смог бы отличить одни от
//! других. Конфиг живёт до конца процесса, поэтому парсеру передаётся арена.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: *Table,

    pub fn asString(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(v: Value) ?i64 {
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asFloat(v: Value) ?f64 {
        return switch (v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asBool(v: Value) ?bool {
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asArray(v: Value) ?[]Value {
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asTable(v: Value) ?*Table {
        return switch (v) {
            .table => |t| t,
            else => null,
        };
    }
};

pub const Table = struct {
    /// Порядок вставки сохраняется: он совпадает с порядком в файле и нужен
    /// для предсказуемой диагностики. Канонический вид, наоборот, ключи
    /// сортирует — см. writeCanonical.
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,

    /// Таблица объявлена собственным заголовком `[a]`, а не создана неявно
    /// по пути `a.b`. Нужно, чтобы поймать повторное объявление.
    explicit: bool = false,

    /// Таблица записана как inline: `{ k = v }`. Такие TOML запрещает
    /// дополнять позже.
    inline_table: bool = false,

    pub const empty: Table = .{};

    pub fn create(gpa: Allocator) Allocator.Error!*Table {
        const t = try gpa.create(Table);
        t.* = .empty;
        return t;
    }

    pub fn get(t: *const Table, key: []const u8) ?Value {
        return t.map.get(key);
    }

    /// Значение по составному пути: `getPath("profiles.dev.env")`.
    pub fn getPath(t: *const Table, path: []const u8) ?Value {
        var cur = t;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            const v = cur.map.get(part) orelse return null;
            if (it.peek() == null) return v;
            cur = v.asTable() orelse return null;
        }
        return null;
    }

    pub fn keys(t: *const Table) []const []const u8 {
        return t.map.keys();
    }

    pub fn count(t: *const Table) usize {
        return t.map.count();
    }

    pub fn put(t: *Table, gpa: Allocator, key: []const u8, v: Value) Allocator.Error!void {
        try t.map.put(gpa, key, v);
    }
};

// ---- каноническое представление --------------------------------------------
//
// Из него считается хеш, по которому trust-store узнаёт конфиг. Требование к
// формату ровно одно: одинаковое СОДЕРЖИМОЕ обязано давать одинаковые байты,
// разное — разные. Форматирование, порядок ключей, стиль кавычек и
// комментарии на хеш влиять не должны.
//
// Это НЕ валидный TOML и не задумывался таковым: перед нами вход для
// хеш-функции, а не файл для чтения. Плоская форма с полными путями ключей
// проще и надёжнее, чем воспроизведение секций.
//
// Формат отличается от Go-версии, которая брала хеш от повторной сериализации
// через BurntSushi. Воспроизвести её байт в байт без самой библиотеки нельзя,
// поэтому записи trust переезжают на version 2 (см. шаг 17 плана).

/// Одна строка канонического вида: `"a"."b" = "value"`.
///
/// Ключи и строки кодируются как строки JSON. Это существенно: без кавычек
/// ключ `a.b` и путь `a` → `b` дали бы одинаковый текст, и подмена одного
/// другим не изменила бы хеш.
pub fn writeCanonical(gpa: Allocator, w: *Writer, root: *const Table) CanonicalError!void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);

    try collect(gpa, &lines, &path, root);

    // Сортировка по готовой строке: порядок ключей в файле на хеш не влияет.
    std.mem.sort([]const u8, lines.items, {}, lessThanSlice);
    for (lines.items) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

/// Набор указан явно: collect и collectValue вызывают друг друга, а
/// выводимый набор ошибок в такой паре даёт цикл зависимостей.
pub const CanonicalError = Allocator.Error || Writer.Error;

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collect(
    gpa: Allocator,
    lines: *std.ArrayList([]const u8),
    path: *std.ArrayList(u8),
    t: *const Table,
) CanonicalError!void {
    // Пустая таблица обязана оставить след, иначе `[a]` без содержимого и
    // полное отсутствие `a` дали бы один и тот же хеш.
    if (t.count() == 0 and path.items.len > 0) {
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} = {{}}", .{path.items}));
        return;
    }

    for (t.map.keys(), t.map.values()) |key, value| {
        const saved = path.items.len;
        defer path.shrinkRetainingCapacity(saved);

        if (saved > 0) try path.append(gpa, '.');
        try appendJsonString(gpa, path, key);
        try collectValue(gpa, lines, path, value);
    }
}

fn collectValue(
    gpa: Allocator,
    lines: *std.ArrayList([]const u8),
    path: *std.ArrayList(u8),
    value: Value,
) CanonicalError!void {
    switch (value) {
        .table => |sub| try collect(gpa, lines, path, sub),
        .array => |items| {
            // Массив таблиц раскрывается по индексам: таблицы внутри него
            // сами содержат ключи, и склеить их в одну строку нельзя.
            if (items.len > 0 and items[0] == .table) {
                for (items, 0..) |item, i| {
                    const saved = path.items.len;
                    defer path.shrinkRetainingCapacity(saved);
                    const idx = try std.fmt.allocPrint(gpa, "[{d}]", .{i});
                    defer gpa.free(idx);
                    try path.appendSlice(gpa, idx);
                    try collectValue(gpa, lines, path, item);
                }
                return;
            }
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            try line.appendSlice(gpa, path.items);
            try line.appendSlice(gpa, " = ");
            try writeScalarValue(gpa, &line, value);
            try lines.append(gpa, try gpa.dupe(u8, line.items));
        },
        else => {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            try line.appendSlice(gpa, path.items);
            try line.appendSlice(gpa, " = ");
            try writeScalarValue(gpa, &line, value);
            try lines.append(gpa, try gpa.dupe(u8, line.items));
        },
    }
}

fn writeScalarValue(gpa: Allocator, out: *std.ArrayList(u8), value: Value) CanonicalError!void {
    switch (value) {
        .string => |s| try appendJsonString(gpa, out, s),
        .integer => |i| try appendFormatted(gpa, out, "{d}", .{i}),
        .float => |f| try appendFormatted(gpa, out, "{d}", .{f}),
        .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .array => |items| {
            try out.append(gpa, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try writeScalarValue(gpa, out, item);
            }
            try out.append(gpa, ']');
        },
        // Таблицы внутри массива разворачиваются в collectValue.
        .table => try out.appendSlice(gpa, "{}"),
    }
}

fn appendFormatted(gpa: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) CanonicalError!void {
    const text = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(text);
    try out.appendSlice(gpa, text);
}

fn appendJsonString(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) CanonicalError!void {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(s, .{}, &aw.writer);
    try out.appendSlice(gpa, aw.written());
}

/// Хеш канонического вида: `"sha256:<hex>"`.
pub fn canonicalHash(gpa: Allocator, root: *const Table) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // Writer здесь свой и пишет в память, поэтому единственная настоящая
    // причина отказа — нехватка памяти. Сужаем тип, чтобы ошибка записи не
    // расползалась по сигнатурам всех вызывающих.
    writeCanonical(gpa, &aw.writer, root) catch return error.OutOfMemory;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(aw.written(), &digest, .{});
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Собирает таблицу вручную, без парсера: тесты этого файла проверяют
/// каноническое представление, а не разбор.
fn buildTable(gpa: Allocator, pairs: []const struct { []const u8, Value }) !*Table {
    const t = try Table.create(gpa);
    for (pairs) |p| try t.put(gpa, p[0], p[1]);
    return t;
}

fn canonical(gpa: Allocator, t: *const Table) ![]const u8 {
    var aw: Writer.Allocating = .init(gpa);
    try writeCanonical(gpa, &aw.writer, t);
    return aw.written();
}

test "value accessors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v: Value = .{ .string = "x" };
    try testing.expectEqualStrings("x", v.asString().?);
    try testing.expect(v.asInt() == null);
    try testing.expect(v.asBool() == null);

    try testing.expectEqual(@as(i64, 5), (Value{ .integer = 5 }).asInt().?);
    try testing.expectEqual(true, (Value{ .boolean = true }).asBool().?);
    // Целое читается и как дробное: TOML различает их, а потребителю обычно
    // всё равно.
    try testing.expectEqual(@as(f64, 5), (Value{ .integer = 5 }).asFloat().?);

    const inner = try buildTable(a, &.{.{ "k", .{ .string = "v" } }});
    const outer = try buildTable(a, &.{.{ "t", .{ .table = inner } }});
    try testing.expectEqualStrings("v", outer.getPath("t.k").?.asString().?);
    try testing.expect(outer.getPath("t.missing") == null);
    try testing.expect(outer.getPath("missing.k") == null);
    // Путь сквозь не-таблицу обрывается, а не падает.
    try testing.expect(inner.getPath("k.deeper") == null);
}

test "canonical form sorts keys and quotes them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const t = try buildTable(a, &.{
        .{ "zebra", .{ .string = "last" } },
        .{ "alpha", .{ .integer = 1 } },
        .{ "middle", .{ .boolean = false } },
    });
    try testing.expectEqualStrings(
        \\"alpha" = 1
        \\"middle" = false
        \\"zebra" = "last"
        \\
    , try canonical(a, t));
}

// Порядок ключей в файле не должен влиять на хеш: иначе перестановка двух
// строк требовала бы повторного одобрения конфига.
test "key order does not change the hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try buildTable(a, &.{
        .{ "a", .{ .integer = 1 } },
        .{ "b", .{ .integer = 2 } },
    });
    const other = try buildTable(a, &.{
        .{ "b", .{ .integer = 2 } },
        .{ "a", .{ .integer = 1 } },
    });
    try testing.expectEqualStrings(try canonicalHash(a, one), try canonicalHash(a, other));
}

// А вот любое смысловое различие обязано менять хеш — в этом весь смысл.
test "any semantic difference changes the hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try canonicalHash(a, try buildTable(a, &.{.{ "k", .{ .string = "v" } }}));

    const different = [_]*Table{
        try buildTable(a, &.{.{ "k", .{ .string = "w" } }}), // другое значение
        try buildTable(a, &.{.{ "j", .{ .string = "v" } }}), // другой ключ
        try buildTable(a, &.{.{ "k", .{ .integer = 1 } }}), // другой тип
        try buildTable(a, &.{ .{ "k", .{ .string = "v" } }, .{ "extra", .{ .integer = 1 } } }),
        try buildTable(a, &.{}), // пусто
    };
    for (different) |t| {
        try testing.expect(!std.mem.eql(u8, base, try canonicalHash(a, t)));
    }
}

// Ключ с точкой внутри и вложенная таблица — разные вещи. Без кавычек вокруг
// частей пути они дали бы одинаковый текст, и подмена одного другим прошла
// бы мимо хеша.
test "a dotted key differs from a nested table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = try buildTable(a, &.{.{ "a.b", .{ .integer = 1 } }});
    const nested = try buildTable(a, &.{
        .{ "a", .{ .table = try buildTable(a, &.{.{ "b", .{ .integer = 1 } }}) } },
    });

    try testing.expectEqualStrings("\"a.b\" = 1\n", try canonical(a, flat));
    try testing.expectEqualStrings("\"a\".\"b\" = 1\n", try canonical(a, nested));
    try testing.expect(!std.mem.eql(u8, try canonicalHash(a, flat), try canonicalHash(a, nested)));
}

test "strings are escaped unambiguously" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Перевод строки и его двухсимвольная запись обязаны различаться.
    const real_newline = try buildTable(a, &.{.{ "k", .{ .string = "a\nb" } }});
    const literal_text = try buildTable(a, &.{.{ "k", .{ .string = "a\\nb" } }});
    try testing.expectEqualStrings("\"k\" = \"a\\nb\"\n", try canonical(a, real_newline));
    try testing.expect(!std.mem.eql(u8, try canonicalHash(a, real_newline), try canonicalHash(a, literal_text)));

    // Кавычка внутри значения не должна ломать разметку строки.
    const quoted = try buildTable(a, &.{.{ "k", .{ .string = "say \"hi\"" } }});
    try testing.expectEqualStrings("\"k\" = \"say \\\"hi\\\"\"\n", try canonical(a, quoted));
}

test "arrays and empty tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var items = [_]Value{ .{ .string = "x" }, .{ .integer = 2 }, .{ .boolean = true } };
    const t = try buildTable(a, &.{
        .{ "arr", .{ .array = &items } },
        .{ "empty_arr", .{ .array = &[_]Value{} } },
        .{ "empty_table", .{ .table = try Table.create(a) } },
    });
    try testing.expectEqualStrings(
        \\"arr" = ["x", 2, true]
        \\"empty_arr" = []
        \\"empty_table" = {}
        \\
    , try canonical(a, t));
}

// Пустая таблица обязана оставить след: иначе `[a]` без содержимого и полное
// отсутствие `a` дали бы одинаковый хеш.
test "an empty table is distinguishable from a missing one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_empty = try buildTable(a, &.{.{ "a", .{ .table = try Table.create(a) } }});
    const without = try buildTable(a, &.{});
    try testing.expect(!std.mem.eql(u8, try canonicalHash(a, with_empty), try canonicalHash(a, without)));
}

test "arrays of tables expand by index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var items = [_]Value{
        .{ .table = try buildTable(a, &.{.{ "path", .{ .string = ".env" } }}) },
        .{ .table = try buildTable(a, &.{.{ "path", .{ .string = ".env.local" } }}) },
    };
    const t = try buildTable(a, &.{.{ "file", .{ .array = &items } }});
    try testing.expectEqualStrings(
        \\"file"[0]."path" = ".env"
        \\"file"[1]."path" = ".env.local"
        \\
    , try canonical(a, t));

    // Порядок элементов массива значим, в отличие от порядка ключей.
    var swapped = [_]Value{ items[1], items[0] };
    const other = try buildTable(a, &.{.{ "file", .{ .array = &swapped } }});
    try testing.expect(!std.mem.eql(u8, try canonicalHash(a, t), try canonicalHash(a, other)));
}

test "the hash is a sha256 hex string with a prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = try canonicalHash(a, try buildTable(a, &.{.{ "k", .{ .string = "v" } }}));
    try testing.expect(std.mem.startsWith(u8, h, "sha256:"));
    try testing.expectEqual(@as(usize, "sha256:".len + 64), h.len);
    for (h["sha256:".len..]) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Golden-значение, посчитанное независимо (shasum -a 256 от строки
    // `"k" = "v"` с переводом строки). Если оно изменилось, изменился формат
    // канонического вида, а значит все существующие записи trust стали
    // недействительны. Менять только сознательно, вместе с версией записи.
    try testing.expectEqualStrings(
        "sha256:f1f32b088bcd68b0df2ece2b5c30e63a790fc7ccfe9a7bc0c32acfaf769b908a",
        h,
    );
}
