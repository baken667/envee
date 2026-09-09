//! Протокол плагина со стороны плагина: разбор запроса `resolve` и форма
//! ответов. Общее для всех плагинов, которые поставляются с envee; сам
//! протокол описан в docs/adr/0007-plugin-protocol.md, а сторона ядра —
//! в `src/plugin.zig`.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Environ = std.process.Environ.Map;

const time_fmt = @import("../trust/store.zig");

pub const api_version: i64 = 1;
/// TTL ответа по умолчанию — 15 минут, как в Go SDK.
pub const default_ttl_seconds: i64 = 900;

/// То, с чем плагин запускается. Отдельная структура, чтобы логику можно
/// было гонять в тестах без процесса.
pub const Input = struct {
    argv: []const []const u8,
    stdin: []const u8,
    environ: *const Environ,
    /// Момент ответа, для `resolved_at`.
    now_ns: i128,
};

/// Разобранный запрос `resolve`.
pub const Request = struct {
    request_id: []const u8 = "",
    ref: []const u8 = "",
    /// Блок `context` от ядра: каталог конфига, cwd и активный профиль.
    config_root: []const u8 = "",
    cwd: []const u8 = "",
    profile: []const u8 = "",
};

pub const ParseError = error{
    /// Тело — не JSON-объект.
    InvalidRequest,
    /// `api_version` не тот, что умеет плагин.
    VersionMismatch,
} || Allocator.Error;

/// Разбирает тело запроса. Версия проверяется здесь же: ядро другой
/// версии могло изменить смысл полей, и молча отвечать ему нельзя.
pub fn parseRequest(arena: Allocator, body: []const u8) ParseError!Request {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidRequest;
    if (parsed != .object) return error.InvalidRequest;
    const o = parsed.object;

    var req: Request = .{ .request_id = stringField(o, "request_id") orelse "" };
    const version: i64 = if (o.get("api_version")) |v| (if (v == .integer) v.integer else 0) else 0;
    if (version != api_version) return error.VersionMismatch;

    if (o.get("spec")) |spec| if (spec == .object) {
        req.ref = stringField(spec.object, "ref") orelse "";
    };
    if (o.get("context")) |ctx| if (ctx == .object) {
        req.config_root = stringField(ctx.object, "config_root") orelse "";
        req.cwd = stringField(ctx.object, "cwd") orelse "";
        req.profile = stringField(ctx.object, "profile") orelse "";
    };
    return req;
}

pub fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Успешный ответ со строковым значением.
pub fn writeOk(arena: Allocator, out: *Writer, request_id: []const u8, value: []const u8, now_ns: i128, source: []const u8) Allocator.Error!void {
    var body: Writer.Allocating = .init(arena);
    const w = &body.writer;
    w.writeAll("{\"api_version\":1,\"request_id\":") catch return error.OutOfMemory;
    std.json.Stringify.value(request_id, .{}, w) catch return error.OutOfMemory;
    w.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"string\",\"value\":") catch return error.OutOfMemory;
    std.json.Stringify.value(value, .{}, w) catch return error.OutOfMemory;
    w.print("}},\"metadata\":{{\"resolved_at\":\"{s}\",\"ttl_seconds\":{d},\"source\":", .{
        try time_fmt.formatRfc3339(arena, now_ns),
        default_ttl_seconds,
    }) catch return error.OutOfMemory;
    std.json.Stringify.value(source, .{}, w) catch return error.OutOfMemory;
    w.writeAll("}}\n") catch return error.OutOfMemory;
    out.writeAll(body.written()) catch {};
}

/// Ошибка уходит в stdout структурой, а не в stderr текстом: ядро читает
/// её оттуда и показывает пользователю код и сообщение плагина.
pub fn writeError(arena: Allocator, out: *Writer, request_id: []const u8, code: []const u8, message: []const u8, recoverable: bool) Allocator.Error!void {
    var body: Writer.Allocating = .init(arena);
    const w = &body.writer;
    w.writeAll("{\"api_version\":1,\"request_id\":") catch return error.OutOfMemory;
    std.json.Stringify.value(request_id, .{}, w) catch return error.OutOfMemory;
    w.writeAll(",\"status\":\"error\",\"error\":{\"code\":") catch return error.OutOfMemory;
    std.json.Stringify.value(code, .{}, w) catch return error.OutOfMemory;
    w.writeAll(",\"message\":") catch return error.OutOfMemory;
    std.json.Stringify.value(message, .{}, w) catch return error.OutOfMemory;
    w.print(",\"recoverable\":{}}}}}\n", .{recoverable}) catch return error.OutOfMemory;
    out.writeAll(body.written()) catch {};
}

/// Разбор запроса с готовыми ответами на обе ошибки. Возвращает null, когда
/// ответ уже написан и остаётся выйти с кодом 1.
pub fn readRequest(arena: Allocator, out: *Writer, body: []const u8) Allocator.Error!?Request {
    return parseRequest(arena, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => {
            try writeError(arena, out, "", "invalid_request", "parse: request is not valid JSON", false);
            return null;
        },
        error.VersionMismatch => {
            // request_id всё же стоит вернуть, если он читается.
            const id = blk: {
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch break :blk "";
                break :blk if (v == .object) (stringField(v.object, "request_id") orelse "") else "";
            };
            try writeError(arena, out, id, "version_mismatch", try std.fmt.allocPrint(arena, "plugin API version other than {d} is not supported", .{api_version}), false);
            return null;
        },
    };
}

/// Общий `main` для поставляемых плагинов: argv, stdin (только для
/// `resolve`), окружение, потоки и код выхода.
pub fn main(init: std.process.Init, comptime run: fn (Allocator, Io, Input, *Writer, *Writer) Allocator.Error!u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &err_buf);

    var stdin: []const u8 = "";
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "resolve")) {
        var in_buf: [4096]u8 = undefined;
        var stdin_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
        stdin = try stdin_file.interface.allocRemaining(arena, .unlimited);
    }

    const code = try run(arena, io, .{
        .argv = argv,
        .stdin = stdin,
        .environ = init.environ_map,
        .now_ns = Io.Timestamp.now(io, .real).nanoseconds,
    }, &stdout_file.interface, &stderr_file.interface);

    stdout_file.interface.flush() catch {};
    stderr_file.interface.flush() catch {};
    std.process.exit(code);
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;

test "a request is parsed with its context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try parseRequest(a,
        \\{"api_version":1,"request_id":"req-7","spec":{"ref":"x/y"},"context":{"config_root":"/p","cwd":"/p/sub","profile":"prod","env":{"A":"1"}}}
    );
    try testing.expectEqualStrings("req-7", req.request_id);
    try testing.expectEqualStrings("x/y", req.ref);
    try testing.expectEqualStrings("/p", req.config_root);
    try testing.expectEqualStrings("/p/sub", req.cwd);
    try testing.expectEqualStrings("prod", req.profile);

    try testing.expectError(error.InvalidRequest, parseRequest(a, "{not json"));
    try testing.expectError(error.InvalidRequest, parseRequest(a, "[]"));
    try testing.expectError(error.VersionMismatch, parseRequest(a, "{\"api_version\":99,\"spec\":{\"ref\":\"x\"}}"));
}

test "readRequest answers the two parse failures itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: Writer.Allocating = .init(a);
    try testing.expect((try readRequest(a, &out.writer, "nope")) == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"code\":\"invalid_request\"") != null);

    var out2: Writer.Allocating = .init(a);
    try testing.expect((try readRequest(a, &out2.writer, "{\"api_version\":2,\"request_id\":\"r9\"}")) == null);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "\"request_id\":\"r9\",\"status\":\"error\",\"error\":{\"code\":\"version_mismatch\"") != null);
}
