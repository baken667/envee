//! Упорядоченная коллекция переменных окружения.
//!
//! Владение: Map НЕ владеет строками key/value, только своим массивом
//! entries. Строки должны жить дольше, чем Map (в проде — арена процесса).
//!
//! Инвариант: entries всегда отсортирован по key, дубликатов нет. Порядок
//! нужен для детерминированного вывода shell-экспортов и JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    /// Значение маскируется в выводе status/diff.
    redacted: bool = false,
    /// Откуда пришло значение: "toml", "dotenv", "secret", "profile:dev", ...
    source: []const u8 = "",
};

pub const Map = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const empty: Map = .{};

    pub fn deinit(m: *Map, gpa: Allocator) void {
        m.entries.deinit(gpa);
    }

    /// Результат бинарного поиска: либо нашли (и где), либо не нашли
    /// (и куда вставлять, чтобы сохранить порядок).
    const Slot = union(enum) {
        found: usize,
        insert_at: usize,
    };

    fn compareKey(key: []const u8, entry: Entry) std.math.Order {
        return std.mem.order(u8, key, entry.key);
    }

    fn find(m: Map, key: []const u8) Slot {
        const items = m.entries.items;
        const i = std.sort.lowerBound(Entry, items, key, compareKey);
        if (i < items.len and std.mem.eql(u8, items[i].key, key)) {
            return .{ .found = i };
        }
        return .{ .insert_at = i };
    }

    pub fn len(m: Map) usize {
        return m.entries.items.len;
    }

    pub fn get(m: Map, key: []const u8) ?[]const u8 {
        return switch (m.find(key)) {
            .found => |i| m.entries.items[i].value,
            .insert_at => null,
        };
    }

    pub fn getEntry(m: Map, key: []const u8) ?Entry {
        return switch (m.find(key)) {
            .found => |i| m.entries.items[i],
            .insert_at => null,
        };
    }

    /// Записывает значение, СОХРАНЯЯ метаданные существующей записи.
    ///
    /// Это поведение Go-эталона (env.go: Set обновляет только Value), и на
    /// него полагается directive: слой, перезаписывающий значение, не должен
    /// снимать пометку redact, поставленную ранее.
    pub fn set(m: *Map, gpa: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        switch (m.find(key)) {
            .found => |i| m.entries.items[i].value = value,
            .insert_at => |i| try m.entries.insert(gpa, i, .{ .key = key, .value = value }),
        }
    }

    /// Записывает запись целиком, ЗАМЕНЯЯ метаданные (Go: SetWithMeta).
    pub fn setEntry(m: *Map, gpa: Allocator, e: Entry) Allocator.Error!void {
        switch (m.find(e.key)) {
            .found => |i| m.entries.items[i] = e,
            .insert_at => |i| try m.entries.insert(gpa, i, e),
        }
    }

    pub fn unset(m: *Map, key: []const u8) void {
        switch (m.find(key)) {
            .found => |i| _ = m.entries.orderedRemove(i),
            .insert_at => {},
        }
    }

    /// Ключи в отсортированном порядке. Сортировать не нужно: entries уже
    /// хранится отсортированным.
    pub fn keys(m: Map, gpa: Allocator) Allocator.Error![]const []const u8 {
        const out = try gpa.alloc([]const u8, m.entries.items.len);
        for (m.entries.items, out) |e, *slot| slot.* = e.key;
        return out;
    }

    /// Копия массива entries. Строки не копируются (см. заголовок файла).
    pub fn clone(m: Map, gpa: Allocator) Allocator.Error!Map {
        return .{ .entries = try m.entries.clone(gpa) };
    }

    /// Накладывает other поверх m: при конфликте ключей побеждает other,
    /// вместе с его метаданными.
    pub fn merge(m: *Map, gpa: Allocator, other: Map) Allocator.Error!void {
        for (other.entries.items) |e| try m.setEntry(gpa, e);
    }

    /// Env в форме "KEY=VALUE", пригодной для передачи дочернему процессу.
    pub fn asExport(m: Map, gpa: Allocator) Allocator.Error![]const []const u8 {
        const out = try gpa.alloc([]const u8, m.entries.items.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |s| gpa.free(s);
            gpa.free(out);
        }
        for (m.entries.items, out) |e, *slot| {
            slot.* = try std.fmt.allocPrint(gpa, "{s}={s}", .{ e.key, e.value });
            done += 1;
        }
        return out;
    }

    /// Снимок окружения процесса.
    pub fn fromEnviron(gpa: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!Map {
        var m: Map = .empty;
        errdefer m.deinit(gpa);
        var it = environ.iterator();
        while (it.next()) |kv| try m.set(gpa, kv.key_ptr.*, kv.value_ptr.*);
        return m;
    }
};

pub const DiffOp = struct {
    key: []const u8,
    /// true = экспортировать value, false = unset.
    set: bool,
    value: []const u8 = "",
    /// Предыдущее значение, если оно было.
    old: []const u8 = "",
};

/// Что нужно сделать, чтобы из `from` получить `to`. Результат отсортирован
/// по key. Оба списка уже отсортированы, поэтому это один проход.
pub fn diff(gpa: Allocator, from: Map, to: Map) Allocator.Error![]DiffOp {
    var ops: std.ArrayList(DiffOp) = .empty;
    errdefer ops.deinit(gpa);

    const a = from.entries.items;
    const b = to.entries.items;
    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len or j < b.len) {
        // Какая сторона «меньше» по ключу. Если одна закончилась —
        // всё оставшееся с другой стороны идёт как есть.
        const order: std.math.Order = if (i >= a.len)
            .gt
        else if (j >= b.len)
            .lt
        else
            std.mem.order(u8, a[i].key, b[j].key);

        switch (order) {
            .lt => { // есть в from, нет в to → unset
                try ops.append(gpa, .{ .key = a[i].key, .set = false, .old = a[i].value });
                i += 1;
            },
            .gt => { // нет в from, есть в to → set
                try ops.append(gpa, .{ .key = b[j].key, .set = true, .value = b[j].value });
                j += 1;
            },
            .eq => { // есть в обоих → set только если значение изменилось
                if (!std.mem.eql(u8, a[i].value, b[j].value)) {
                    try ops.append(gpa, .{
                        .key = b[j].key,
                        .set = true,
                        .value = b[j].value,
                        .old = a[i].value,
                    });
                }
                i += 1;
                j += 1;
            },
        }
    }
    return ops.toOwnedSlice(gpa);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "set/get/unset" {
    var m: Map = .empty;
    defer m.deinit(testing.allocator);

    try m.set(testing.allocator, "FOO", "bar");
    try m.set(testing.allocator, "BAZ", "qux");

    try testing.expectEqualStrings("bar", m.get("FOO").?);
    try testing.expect(m.get("MISSING") == null);
    try testing.expectEqual(@as(usize, 2), m.len());

    m.unset("FOO");
    try testing.expect(m.get("FOO") == null);
    try testing.expectEqual(@as(usize, 1), m.len());

    // unset несуществующего ключа — не паникует и не меняет размер
    m.unset("NOPE");
    try testing.expectEqual(@as(usize, 1), m.len());
}

test "set overwrites in place, keeps order" {
    var m: Map = .empty;
    defer m.deinit(testing.allocator);

    try m.set(testing.allocator, "Z", "1");
    try m.set(testing.allocator, "A", "2");
    try m.set(testing.allocator, "M", "3");
    try m.set(testing.allocator, "M", "changed");

    try testing.expectEqual(@as(usize, 3), m.len());
    try testing.expectEqualStrings("changed", m.get("M").?);
    try testing.expectEqualStrings("A", m.entries.items[0].key);
    try testing.expectEqualStrings("M", m.entries.items[1].key);
    try testing.expectEqualStrings("Z", m.entries.items[2].key);
}

test "set preserves metadata, setEntry replaces it" {
    var m: Map = .empty;
    defer m.deinit(testing.allocator);

    try m.setEntry(testing.allocator, .{
        .key = "SECRET",
        .value = "old",
        .redacted = true,
        .source = "toml",
    });

    // set меняет только значение
    try m.set(testing.allocator, "SECRET", "new");
    const kept = m.getEntry("SECRET").?;
    try testing.expectEqualStrings("new", kept.value);
    try testing.expect(kept.redacted);
    try testing.expectEqualStrings("toml", kept.source);

    // setEntry заменяет запись целиком
    try m.setEntry(testing.allocator, .{ .key = "SECRET", .value = "plain" });
    const replaced = m.getEntry("SECRET").?;
    try testing.expectEqualStrings("plain", replaced.value);
    try testing.expect(!replaced.redacted);
    try testing.expectEqualStrings("", replaced.source);

    try testing.expect(m.getEntry("MISSING") == null);
}

test "keys sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m: Map = .empty;
    try m.set(a, "Z", "1");
    try m.set(a, "A", "2");
    try m.set(a, "M", "3");

    const ks = try m.keys(a);
    try testing.expectEqual(@as(usize, 3), ks.len);
    try testing.expectEqualStrings("A", ks[0]);
    try testing.expectEqualStrings("M", ks[1]);
    try testing.expectEqualStrings("Z", ks[2]);
}

test "diff: set, change, unset, sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var from: Map = .empty;
    try from.set(a, "X", "1");
    try from.set(a, "Y", "2");
    try from.set(a, "Z", "3");

    var to: Map = .empty;
    try to.set(a, "X", "1"); // без изменений
    try to.set(a, "Y", "NEW"); // изменилось
    try to.set(a, "W", "4"); // добавилось

    const ops = try diff(a, from, to);
    try testing.expectEqual(@as(usize, 3), ops.len);

    // Результат отсортирован по ключу: W, Y, Z.
    try testing.expectEqualStrings("W", ops[0].key);
    try testing.expect(ops[0].set);
    try testing.expectEqualStrings("4", ops[0].value);
    try testing.expectEqualStrings("", ops[0].old);

    try testing.expectEqualStrings("Y", ops[1].key);
    try testing.expect(ops[1].set);
    try testing.expectEqualStrings("NEW", ops[1].value);
    try testing.expectEqualStrings("2", ops[1].old);

    try testing.expectEqualStrings("Z", ops[2].key);
    try testing.expect(!ops[2].set);
    try testing.expectEqualStrings("3", ops[2].old);
}

test "diff of identical maps is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m: Map = .empty;
    try m.set(a, "X", "1");
    try m.set(a, "Y", "2");

    const ops = try diff(a, m, m);
    try testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff against empty maps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m: Map = .empty;
    try m.set(a, "X", "1");
    const none: Map = .empty;

    // Всё добавляется.
    const added = try diff(a, none, m);
    try testing.expectEqual(@as(usize, 1), added.len);
    try testing.expect(added[0].set);

    // Всё удаляется.
    const removed = try diff(a, m, none);
    try testing.expectEqual(@as(usize, 1), removed.len);
    try testing.expect(!removed[0].set);
    try testing.expectEqualStrings("1", removed[0].old);
}

test "merge: other wins, with metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var x: Map = .empty;
    try x.set(a, "X", "1");
    try x.set(a, "Y", "2");

    var y: Map = .empty;
    try y.set(a, "Y", "OVERRIDE");
    try y.setEntry(a, .{ .key = "Z", .value = "3", .redacted = true, .source = "secret" });

    try x.merge(a, y);
    try testing.expectEqualStrings("1", x.get("X").?);
    try testing.expectEqualStrings("OVERRIDE", x.get("Y").?);
    try testing.expectEqualStrings("3", x.get("Z").?);
    try testing.expect(x.getEntry("Z").?.redacted);
}

test "clone is independent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var x: Map = .empty;
    try x.set(a, "X", "1");

    var y = try x.clone(a);
    try y.set(a, "X", "2");
    try y.set(a, "NEW", "3");

    try testing.expectEqualStrings("1", x.get("X").?);
    try testing.expect(x.get("NEW") == null);
    try testing.expectEqualStrings("2", y.get("X").?);
}

test "asExport" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m: Map = .empty;
    try m.set(a, "A", "1");
    try m.set(a, "B", "with spaces");
    try m.set(a, "C", "with=equals");

    const out = try m.asExport(a);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("A=1", out[0]);
    try testing.expectEqualStrings("B=with spaces", out[1]);
    try testing.expectEqualStrings("C=with=equals", out[2]);
}

test "fromEnviron" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: std.process.Environ.Map = .init(a);
    try environ.put("ZZZ", "last");
    try environ.put("AAA", "first");
    try environ.put("MMM", "middle");

    const m = try Map.fromEnviron(a, &environ);
    try testing.expectEqual(@as(usize, 3), m.len());
    // Отсортировано, независимо от порядка вставки.
    try testing.expectEqualStrings("AAA", m.entries.items[0].key);
    try testing.expectEqualStrings("MMM", m.entries.items[1].key);
    try testing.expectEqualStrings("ZZZ", m.entries.items[2].key);
    try testing.expectEqualStrings("first", m.get("AAA").?);
}
