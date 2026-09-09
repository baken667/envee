const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    redacted: bool = false,
    source: []const u8 = "",
};

pub const Map = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const empty: Map = .{};

    pub fn deinit(m: *Map, gpa: Allocator) void {
        m.entries.deinit(gpa);
    }

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
};

pub const DiffOp = struct {
    key: []const u8,
    set: bool,
    value: []const u8 = "",
    old: []const u8 = "",
};

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
