//! Директива `_.file`: подмешивание переменных из внешнего файла.
//!
//! Порт `internal/directive/file.go`.
//!
//! Форматы: `dotenv` (по умолчанию), `json`, `toml`. Формат определяется по
//! расширению, если не задан явно.
//!
//! YAML НЕ поддерживается, в отличие от Go-версии, где он тянул за собой
//! `gopkg.in/yaml.v3`. Ни один пример и ни один тест им не пользуется, а
//! свой разбор YAML стоит больше, чем даёт. Вместо молчаливого пропуска
//! возвращается внятная ошибка. Записано в docs/zig-rewrite-steps.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("../config.zig");
const dotenv = @import("../dotenv.zig");
const env_mod = @import("../env.zig");
const gopath = @import("../path.zig");
const toml = @import("../toml/parser.zig");
const value = @import("../toml/value.zig");

pub const Error = error{
    /// У записи `_.file` не указан путь.
    MissingPath,
    /// Файл объявлен обязательным, но его нет.
    RequiredFileMissing,
    /// Формат не поддерживается (в том числе yaml).
    UnsupportedFormat,
    /// Файл не разобрался.
    ParseFailed,
} || Allocator.Error || std.Io.Dir.ReadFileAllocError;

pub const Diagnostics = struct {
    /// Полный путь к файлу.
    path: []const u8 = "",
    format: []const u8 = "",
    detail: []const u8 = "",
};

/// Что делать с каждой прочитанной парой. Отдельный тип, а не замыкание:
/// в Zig замыкания с состоянием — это указатель плюс контекст, и явная
/// структура честнее.
pub const Sink = struct {
    ctx: *anyopaque,
    setFn: *const fn (ctx: *anyopaque, key: []const u8, val: []const u8) Allocator.Error!void,

    pub fn set(s: Sink, key: []const u8, val: []const u8) Allocator.Error!void {
        return s.setFn(s.ctx, key, val);
    }
};

/// Загружает одну запись `_.file` и отдаёт её переменные в `sink`.
///
/// Относительный путь считается от каталога конфига.
pub fn applyFile(
    arena: Allocator,
    io: std.Io,
    config_root: []const u8,
    ref: config.FileRef,
    os_env: *const env_mod.Map,
    sink: Sink,
    diag: ?*Diagnostics,
) Error!void {
    if (ref.path.len == 0) return error.MissingPath;

    const path = if (std.fs.path.isAbsolute(ref.path))
        ref.path
    else
        try gopath.join(arena, &.{ config_root, ref.path });

    if (diag) |d| d.path = path;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            // Необязательный отсутствующий файл — не ошибка: именно так
            // пишут `_.file = ".env.local"`.
            if (!ref.required) return;
            return error.RequiredFileMissing;
        },
        else => return err,
    };

    const format = if (ref.format.len > 0) ref.format else detectFormat(path);
    if (diag) |d| d.format = format;

    if (eqlIgnoreCase(format, "dotenv") or eqlIgnoreCase(format, ".env")) {
        return loadDotenv(arena, data, ref.expand, os_env, sink, diag);
    }
    if (eqlIgnoreCase(format, "json")) return loadJson(arena, data, sink, diag);
    if (eqlIgnoreCase(format, "toml")) return loadToml(arena, data, sink, diag);
    if (eqlIgnoreCase(format, "yaml") or eqlIgnoreCase(format, "yml")) {
        if (diag) |d| d.detail = "yaml is not supported; use dotenv, json or toml";
        return error.UnsupportedFormat;
    }
    if (diag) |d| d.detail = "unknown file format";
    return error.UnsupportedFormat;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Формат по расширению. Файл без расширения считается dotenv — так
/// написано `.env`.
fn detectFormat(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (eqlIgnoreCase(ext, ".json")) return "json";
    if (eqlIgnoreCase(ext, ".yaml") or eqlIgnoreCase(ext, ".yml")) return "yaml";
    if (eqlIgnoreCase(ext, ".toml")) return "toml";
    return "dotenv";
}

fn loadDotenv(
    arena: Allocator,
    data: []const u8,
    expand: bool,
    os_env: *const env_mod.Map,
    sink: Sink,
    diag: ?*Diagnostics,
) Error!void {
    var parse_diag: dotenv.Diagnostics = .{};
    var vars = (if (expand)
        dotenv.parseWithExpansion(arena, data, os_env, &parse_diag)
    else
        dotenv.parse(arena, data, &parse_diag)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag) |d| d.detail = @errorName(err);
            return error.ParseFailed;
        },
    };
    for (vars.keys()) |k| try sink.set(k, vars.get(k).?);
}

fn loadJson(arena: Allocator, data: []const u8, sink: Sink, diag: ?*Diagnostics) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch |err| {
        if (diag) |d| d.detail = @errorName(err);
        return error.ParseFailed;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            if (diag) |d| d.detail = "the top level must be an object";
            return error.ParseFailed;
        },
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        try flattenJson(arena, sink, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn flattenJson(arena: Allocator, sink: Sink, prefix: []const u8, v: std.json.Value) Error!void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                // Вложенные ключи склеиваются через точку: {"app":{"name":"x"}}
                // даёт app.name.
                const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, entry.key_ptr.* });
                try flattenJson(arena, sink, key, entry.value_ptr.*);
            }
        },
        .array => |items| {
            // Массив склеивается ПРОБЕЛАМИ. Это не описка и не то же самое,
            // что формат массива в [env] (там ", "): в Go это два разных
            // места с разным форматированием, и оба видны пользователю.
            var out: std.ArrayList(u8) = .empty;
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ' ');
                try appendJsonScalar(arena, &out, item);
            }
            try sink.set(prefix, try out.toOwnedSlice(arena));
        },
        else => {
            var out: std.ArrayList(u8) = .empty;
            try appendJsonScalar(arena, &out, v);
            try sink.set(prefix, try out.toOwnedSlice(arena));
        },
    }
}

fn appendJsonScalar(arena: Allocator, out: *std.ArrayList(u8), v: std.json.Value) Allocator.Error!void {
    switch (v) {
        .string => |s| try out.appendSlice(arena, s),
        .integer => |i| try appendFmt(arena, out, "{d}", .{i}),
        .float => |f| try appendFmt(arena, out, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(arena, s),
        .bool => |b| try out.appendSlice(arena, if (b) "true" else "false"),
        .null => try out.appendSlice(arena, "null"),
        // Вложенные объекты и массивы внутри массива печатаются как в Go:
        // через общий форматтер, без разворачивания.
        .object => try out.appendSlice(arena, "map[]"),
        .array => try out.appendSlice(arena, "[]"),
    }
}

fn appendFmt(arena: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const text = try std.fmt.allocPrint(arena, fmt, args);
    defer arena.free(text);
    try out.appendSlice(arena, text);
}

/// TOML-файл: берётся таблица `[env]`, если она есть, иначе весь корень.
fn loadToml(arena: Allocator, data: []const u8, sink: Sink, diag: ?*Diagnostics) Error!void {
    var parse_diag: toml.Diagnostics = .{};
    const root = toml.parse(arena, data, &parse_diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag) |d| d.detail = @errorName(err);
            return error.ParseFailed;
        },
    };
    const table = if (root.get("env")) |e| (e.asTable() orelse root) else root;
    for (table.keys(), table.map.values()) |k, v| {
        try flattenToml(arena, sink, k, v);
    }
}

fn flattenToml(arena: Allocator, sink: Sink, prefix: []const u8, v: value.Value) Error!void {
    switch (v) {
        .table => |t| {
            for (t.keys(), t.map.values()) |k, sub| {
                const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, k });
                try flattenToml(arena, sink, key, sub);
            }
        },
        .array => |items| {
            var out: std.ArrayList(u8) = .empty;
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ' ');
                try appendTomlScalar(arena, &out, item);
            }
            try sink.set(prefix, try out.toOwnedSlice(arena));
        },
        else => {
            var out: std.ArrayList(u8) = .empty;
            try appendTomlScalar(arena, &out, v);
            try sink.set(prefix, try out.toOwnedSlice(arena));
        },
    }
}

fn appendTomlScalar(arena: Allocator, out: *std.ArrayList(u8), v: value.Value) Allocator.Error!void {
    switch (v) {
        .string => |s| try out.appendSlice(arena, s),
        .integer => |i| try appendFmt(arena, out, "{d}", .{i}),
        .float => |f| try appendFmt(arena, out, "{d}", .{f}),
        .boolean => |b| try out.appendSlice(arena, if (b) "true" else "false"),
        .array => try out.appendSlice(arena, "[]"),
        .table => try out.appendSlice(arena, "map[]"),
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Приёмник, складывающий пары в env.Map — как в настоящем оркестраторе.
const CollectSink = struct {
    gpa: Allocator,
    map: env_mod.Map = .empty,

    fn sink(c: *CollectSink) Sink {
        return .{ .ctx = c, .setFn = set };
    }

    fn set(ctx: *anyopaque, key: []const u8, val: []const u8) Allocator.Error!void {
        const self: *CollectSink = @ptrCast(@alignCast(ctx));
        try self.map.set(self.gpa, key, val);
    }
};

const TempDir = struct {
    path: []const u8,

    fn create(gpa: Allocator) !TempDir {
        const io = std.testing.io;
        const cwd_path = try std.process.currentPathAlloc(io, gpa);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const path = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path };
    }

    fn destroy(t: TempDir) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, t.path) catch {};
    }

    fn write(t: TempDir, gpa: Allocator, sub: []const u8, body: []const u8) !void {
        const full = try std.fs.path.join(gpa, &.{ t.path, sub });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = body });
    }
};

fn load(gpa: Allocator, dir: TempDir, ref: config.FileRef) !CollectSink {
    var c: CollectSink = .{ .gpa = gpa };
    var os_env: env_mod.Map = .empty;
    try applyFile(gpa, std.testing.io, dir.path, ref, &os_env, c.sink(), null);
    return c;
}

test "dotenv is the default format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, ".env", "KEY_FROM_DOTENV=from-dotenv\nOTHER=val\n");

    const c = try load(a, tmp, .{ .path = ".env" });
    try testing.expectEqualStrings("from-dotenv", c.map.get("KEY_FROM_DOTENV").?);
    try testing.expectEqualStrings("val", c.map.get("OTHER").?);
}

test "an absolute path is used as given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "abs.env", "A=1\n");

    const full = try std.fs.path.join(a, &.{ tmp.path, "abs.env" });
    const c = try load(a, .{ .path = "/nonexistent" }, .{ .path = full });
    try testing.expectEqualStrings("1", c.map.get("A").?);
}

test "a missing optional file is skipped, a missing required one is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    // Так и пишут `_.file = ".env.local"`: файла может не быть.
    const c = try load(a, tmp, .{ .path = ".env.local" });
    try testing.expectEqual(@as(usize, 0), c.map.len());

    var sink_ctx: CollectSink = .{ .gpa = a };
    var os_env: env_mod.Map = .empty;
    try testing.expectError(error.RequiredFileMissing, applyFile(
        a,
        std.testing.io,
        tmp.path,
        .{ .path = ".env.local", .required = true },
        &os_env,
        sink_ctx.sink(),
        null,
    ));
}

test "an entry without a path is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink_ctx: CollectSink = .{ .gpa = a };
    var os_env: env_mod.Map = .empty;
    try testing.expectError(error.MissingPath, applyFile(
        a,
        std.testing.io,
        "/tmp",
        .{},
        &os_env,
        sink_ctx.sink(),
        null,
    ));
}

test "json, flattened by dots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "vars.json",
        \\{"FLAT": "v", "PORT": 5432, "ON": true,
        \\ "app": {"name": "x", "deep": {"k": "y"}},
        \\ "items": [1, 2, 3]}
    );

    const c = try load(a, tmp, .{ .path = "vars.json" });
    try testing.expectEqualStrings("v", c.map.get("FLAT").?);
    try testing.expectEqualStrings("5432", c.map.get("PORT").?);
    try testing.expectEqualStrings("true", c.map.get("ON").?);
    try testing.expectEqualStrings("x", c.map.get("app.name").?);
    try testing.expectEqualStrings("y", c.map.get("app.deep.k").?);
    // Массив склеивается пробелами.
    try testing.expectEqualStrings("1 2 3", c.map.get("items").?);
}

test "toml, with and without an env table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "with.toml", "[env]\nA = \"1\"\nN = 2\n");
    try tmp.write(a, "without.toml", "B = \"2\"\nnested.k = \"v\"\n");

    const with = try load(a, tmp, .{ .path = "with.toml" });
    try testing.expectEqualStrings("1", with.map.get("A").?);
    try testing.expectEqualStrings("2", with.map.get("N").?);

    const without = try load(a, tmp, .{ .path = "without.toml" });
    try testing.expectEqualStrings("2", without.map.get("B").?);
    try testing.expectEqualStrings("v", without.map.get("nested.k").?);
}

test "the format can be forced, overriding the extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "looks-like.txt", "{\"A\": \"json-after-all\"}");

    const c = try load(a, tmp, .{ .path = "looks-like.txt", .format = "json" });
    try testing.expectEqualStrings("json-after-all", c.map.get("A").?);
}

test "expansion inside a dotenv file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, ".env", "BIN=\"$HOME/bin\"\n");

    var os_env: env_mod.Map = .empty;
    try os_env.set(a, "HOME", "/home/alice");

    var c_off: CollectSink = .{ .gpa = a };
    try applyFile(a, std.testing.io, tmp.path, .{ .path = ".env" }, &os_env, c_off.sink(), null);
    try testing.expectEqualStrings("$HOME/bin", c_off.map.get("BIN").?);

    var c_on: CollectSink = .{ .gpa = a };
    try applyFile(a, std.testing.io, tmp.path, .{ .path = ".env", .expand = true }, &os_env, c_on.sink(), null);
    try testing.expectEqualStrings("/home/alice/bin", c_on.map.get("BIN").?);
}

// YAML сознательно не поддерживается: он тянул в Go-версию отдельную
// зависимость, а не используется ни примерами, ни тестами.
test "yaml is refused with an explanation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "vars.yaml", "A: 1\n");

    var sink_ctx: CollectSink = .{ .gpa = a };
    var os_env: env_mod.Map = .empty;
    var diag: Diagnostics = .{};
    try testing.expectError(error.UnsupportedFormat, applyFile(
        a,
        std.testing.io,
        tmp.path,
        .{ .path = "vars.yaml" },
        &os_env,
        sink_ctx.sink(),
        &diag,
    ));
    try testing.expect(std.mem.indexOf(u8, diag.detail, "yaml") != null);
}

test "an unknown format is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "f.txt", "A=1\n");

    var sink_ctx: CollectSink = .{ .gpa = a };
    var os_env: env_mod.Map = .empty;
    try testing.expectError(error.UnsupportedFormat, applyFile(
        a,
        std.testing.io,
        tmp.path,
        .{ .path = "f.txt", .format = "xml" },
        &os_env,
        sink_ctx.sink(),
        null,
    ));
}

test "a malformed file names the file and the format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "broken.json", "{not json");

    var sink_ctx: CollectSink = .{ .gpa = a };
    var os_env: env_mod.Map = .empty;
    var diag: Diagnostics = .{};
    try testing.expectError(error.ParseFailed, applyFile(
        a,
        std.testing.io,
        tmp.path,
        .{ .path = "broken.json" },
        &os_env,
        sink_ctx.sink(),
        &diag,
    ));
    try testing.expect(std.mem.endsWith(u8, diag.path, "broken.json"));
    try testing.expectEqualStrings("json", diag.format);
}
