//! Локальное хранилище секретов: файл, который пишет `envee secret set` и
//! читает `envee-plugin-env`.
//!
//! Вынесено отдельно и без зависимостей, потому что файл читают две
//! программы, и место с форматом они обязаны понимать буквально одинаково.
//! Формат — как у Go-плагина, чтобы существующие файлы пользователей
//! продолжили работать: JSON-объект «ключ → строка», отступ два пробела,
//! ключи по алфавиту, режим 0600.
//!
//! Путь: `$XDG_DATA_HOME/envee/secrets/env.json`, иначе
//! `~/.local/share/envee/secrets/env.json` — на любой ОС, в отличие от
//! `paths.zig`: так делает Go-плагин, и менять это можно только вместе с ним.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const Secrets = std.StringArrayHashMapUnmanaged([]const u8);

pub const LoadError = error{
    /// Файл есть, но это не JSON-объект строк.
    Malformed,
    /// Файл не прочитался (кроме отсутствия — оно означает пустое хранилище).
    ReadFailed,
} || Allocator.Error;

pub const SaveError = error{WriteFailed} || Allocator.Error;

pub fn path(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    const xdg = environ.get("XDG_DATA_HOME") orelse "";
    const dir = if (xdg.len > 0)
        xdg
    else
        try std.fs.path.join(arena, &.{ environ.get("HOME") orelse "", ".local", "share" });
    return std.fs.path.join(arena, &.{ dir, "envee", "secrets", "env.json" });
}

/// Читает хранилище; отсутствующий файл — пустое хранилище.
pub fn load(arena: Allocator, io: Io, file_path: []const u8) LoadError!Secrets {
    const out: Secrets = .empty;
    const data = Io.Dir.cwd().readFileAlloc(io, file_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return out,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    return parse(arena, data);
}

pub fn parse(arena: Allocator, data: []const u8) LoadError!Secrets {
    var out: Secrets = .empty;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.Malformed;
    if (parsed != .object) return error.Malformed;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) return error.Malformed;
        try out.put(arena, e.key_ptr.*, e.value_ptr.string);
    }
    return out;
}

/// Сериализация в точности как `json.MarshalIndent(m, "", "  ")` в Go.
pub fn render(arena: Allocator, secrets: Secrets) Allocator.Error![]const u8 {
    const keys = try arena.dupe([]const u8, secrets.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);

    var body: Writer.Allocating = .init(arena);
    const w = &body.writer;
    if (keys.len == 0) {
        w.writeAll("{}") catch return error.OutOfMemory;
        return body.written();
    }
    w.writeAll("{\n") catch return error.OutOfMemory;
    for (keys, 0..) |k, i| {
        w.writeAll("  ") catch return error.OutOfMemory;
        std.json.Stringify.value(k, .{}, w) catch return error.OutOfMemory;
        w.writeAll(": ") catch return error.OutOfMemory;
        std.json.Stringify.value(secrets.get(k).?, .{}, w) catch return error.OutOfMemory;
        w.writeAll(if (i + 1 < keys.len) ",\n" else "\n") catch return error.OutOfMemory;
    }
    w.writeAll("}") catch return error.OutOfMemory;
    return body.written();
}

/// Пишет хранилище целиком: временный файл рядом + rename, чтобы
/// параллельный читатель (плагин из другого процесса) не увидел полфайла.
pub fn save(arena: Allocator, io: Io, file_path: []const u8, secrets: Secrets) SaveError!void {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    const cwd = Io.Dir.cwd();
    _ = cwd.createDirPathStatus(io, dir, .fromMode(0o700)) catch return error.WriteFailed;

    const body = try render(arena, secrets);
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const tmp_path = try std.fmt.allocPrint(arena, "{s}/env-{x}.json.tmp", .{ dir, &random_bytes });
    cwd.writeFile(io, .{
        .sub_path = tmp_path,
        .data = body,
        .flags = .{ .permissions = .fromMode(0o600) },
    }) catch return error.WriteFailed;
    errdefer cwd.deleteFile(io, tmp_path) catch {};
    cwd.rename(tmp_path, cwd, file_path, io) catch return error.WriteFailed;
}

pub fn sortedKeys(arena: Allocator, secrets: Secrets) Allocator.Error![]const []const u8 {
    const keys = try arena.dupe([]const u8, secrets.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    return keys;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

test "the store path follows XDG_DATA_HOME and falls back to ~/.local/share" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: std.process.Environ.Map = .init(a);
    try environ.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.local/share/envee/secrets/env.json", try path(a, &environ));
    try environ.put("XDG_DATA_HOME", "/data");
    try testing.expectEqualStrings("/data/envee/secrets/env.json", try path(a, &environ));
}

test "render matches Go's MarshalIndent and parse reads it back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s: Secrets = .empty;
    try testing.expectEqualStrings("{}", try render(a, s));
    try s.put(a, "Z", "last");
    try s.put(a, "A", "a=b \"q\"");
    try testing.expectEqualStrings("{\n  \"A\": \"a=b \\\"q\\\"\",\n  \"Z\": \"last\"\n}", try render(a, s));

    const back = try parse(a, try render(a, s));
    try testing.expectEqualStrings("a=b \"q\"", back.get("A").?);
    try testing.expectEqualStrings("last", back.get("Z").?);

    try testing.expectError(error.Malformed, parse(a, "{\"A\": 1}"));
    try testing.expectError(error.Malformed, parse(a, "[]"));
    try testing.expectError(error.Malformed, parse(a, "not json"));
}
