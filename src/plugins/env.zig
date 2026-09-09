//! `envee-plugin-env`: плагин секретов над локальным хранилищем.
//!
//! Порт `plugins/env/main.go` вместе с той частью `pkg/sdk-go/protocol.go`,
//! что отвечает за разбор запроса и форму ответа. Логика вынесена из
//! `main` в чистую функцию `run`, чтобы её можно было тестировать без
//! процесса: на входе argv, stdin и окружение, на выходе stdout и код.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const perms = @import("../perms.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Environ = std.process.Environ.Map;

const build_options = @import("build_options");
const store = @import("../secret_store.zig");
const time_fmt = @import("../trust/store.zig");

pub const name = "env";
pub const api_version: i64 = 1;
/// TTL по умолчанию — 15 минут, как в Go.
pub const ttl_seconds: i64 = 900;

pub const Input = struct {
    argv: []const []const u8,
    stdin: []const u8,
    environ: *const Environ,
    /// Момент ответа, для `resolved_at`.
    now_ns: i128,
};

/// Выполняет подкоманду и возвращает код выхода. Всё, что плагин говорит
/// ядру, идёт в `out` (stdout); человеку — в `err_out`.
pub fn run(arena: Allocator, io: Io, in: Input, out: *Writer, err_out: *Writer) Allocator.Error!u8 {
    if (in.argv.len < 2) {
        err_out.writeAll("usage: envee-plugin-env <metadata|resolve|version>\n") catch {};
        return 2;
    }
    const sub = in.argv[1];
    if (std.mem.eql(u8, sub, "metadata")) {
        writeMetadata(out) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "version")) {
        out.print("envee-plugin-env version {s}\n", .{build_options.version}) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "resolve")) return resolve(arena, io, in, out);
    err_out.print("unknown subcommand: {s}\n", .{sub}) catch {};
    return 2;
}

fn writeMetadata(out: *Writer) Writer.Error!void {
    try out.writeAll("{\"name\":\"env\",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, out);
    try out.writeAll(",\"api_version\":1,\"description\":\"Local key-value secret store (envee secret set/unset/list)\"," ++
        "\"capabilities\":[\"secret\"],\"permissions\":{\"network\":false," ++
        "\"filesystem\":[\"$XDG_DATA_HOME/envee/secrets/env.json\"],\"exec\":[]}}\n");
}

fn resolve(arena: Allocator, io: Io, in: Input, out: *Writer) Allocator.Error!u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, in.stdin, .{}) catch {
        try writeError(arena, out, "", "invalid_request", "parse: request is not valid JSON", false);
        return 1;
    };
    const obj: ?std.json.ObjectMap = if (parsed == .object) parsed.object else null;
    const request_id = if (obj) |o| stringField(o, "request_id") orelse "" else "";

    const got_version: i64 = if (obj) |o| (if (o.get("api_version")) |v| (if (v == .integer) v.integer else 0) else 0) else 0;
    if (got_version != api_version) {
        try writeError(arena, out, request_id, "version_mismatch", try std.fmt.allocPrint(arena, "plugin API version {d}, expected {d}", .{ got_version, api_version }), false);
        return 1;
    }

    var ref: []const u8 = "";
    if (obj.?.get("spec")) |spec| if (spec == .object) {
        ref = stringField(spec.object, "ref") orelse "";
    };
    if (ref.len == 0) {
        try writeError(arena, out, request_id, "invalid_spec", "ref is required", false);
        return 1;
    }

    const path = try store.path(arena, in.environ);
    const secrets = store.load(arena, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => {
            try writeError(arena, out, request_id, "internal", try std.fmt.allocPrint(arena, "parse {s}: not a JSON object of strings", .{path}), true);
            return 1;
        },
        error.ReadFailed => {
            try writeError(arena, out, request_id, "internal", try std.fmt.allocPrint(arena, "read {s}: failed", .{path}), true);
            return 1;
        },
    };
    const value = secrets.get(ref) orelse {
        try writeError(arena, out, request_id, "not_found", try std.fmt.allocPrint(arena, "secret \"{s}\" not found in env store", .{ref}), true);
        return 1;
    };

    var body: Writer.Allocating = .init(arena);
    const w = &body.writer;
    w.writeAll("{\"api_version\":1,\"request_id\":") catch return error.OutOfMemory;
    std.json.Stringify.value(request_id, .{}, w) catch return error.OutOfMemory;
    w.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"string\",\"value\":") catch return error.OutOfMemory;
    std.json.Stringify.value(value, .{}, w) catch return error.OutOfMemory;
    w.print("}},\"metadata\":{{\"resolved_at\":\"{s}\",\"ttl_seconds\":{d},\"source\":\"\"}}}}\n", .{
        try time_fmt.formatRfc3339(arena, in.now_ns),
        ttl_seconds,
    }) catch return error.OutOfMemory;
    out.writeAll(body.written()) catch {};
    return 0;
}

/// Ошибка уходит в stdout структурой, а не в stderr текстом: ядро читает
/// её оттуда и показывает пользователю код и сообщение плагина.
fn writeError(arena: Allocator, out: *Writer, request_id: []const u8, code: []const u8, message: []const u8, recoverable: bool) Allocator.Error!void {
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

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ---- тесты -------------------------------------------------------------------
//
// Порт `pkg/sdk-go/protocol_test.go` в части, применимой к этому плагину;
// плюс поведение самого плагина из `plugins/env/main.go`.

const testing = std.testing;
const plugin_mod = @import("../plugin.zig");
const harness = @import("../cli/test_harness.zig");

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn runWith(a: Allocator, environ: *const Environ, argv: []const []const u8, stdin: []const u8) !Run {
    var out: Writer.Allocating = .init(a);
    var err_out: Writer.Allocating = .init(a);
    const code = try run(a, testing.io, .{
        .argv = argv,
        .stdin = stdin,
        .environ = environ,
        .now_ns = 1_700_000_000 * std.time.ns_per_s,
    }, &out.writer, &err_out.writer);
    return .{ .code = code, .stdout = out.written(), .stderr = err_out.written() };
}

fn request(a: Allocator, version: i64, ref: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"api_version\":{d},\"request_id\":\"req-1\",\"spec\":{{\"ref\":\"{s}\"}},\"context\":{{\"config_root\":\"\",\"cwd\":\"\",\"profile\":\"\",\"env\":{{}}}}}}", .{ version, ref });
}

fn response(a: Allocator, stdout: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, stdout, .{});
    try testing.expect(v == .object);
    return v.object;
}

fn errorCode(o: std.json.ObjectMap) []const u8 {
    return stringField(o.get("error").?.object, "code").?;
}

const Fixture = struct {
    tmp: harness.TempDir,
    environ: Environ,

    fn create(a: Allocator) !Fixture {
        const tmp = try harness.TempDir.create(a);
        var environ: Environ = .init(a);
        try environ.put("HOME", tmp.path);
        try environ.put("XDG_DATA_HOME", try tmp.join(a, "xdg"));
        return .{ .tmp = tmp, .environ = environ };
    }

    fn seed(f: *const Fixture, a: Allocator, pairs: []const [2][]const u8) !void {
        var s: store.Secrets = .empty;
        for (pairs) |p| try s.put(a, p[0], p[1]);
        try store.save(a, testing.io, try store.path(a, &f.environ), s);
    }
};

test "metadata is what the core expects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a);
    defer f.tmp.destroy();

    const r = try runWith(a, &f.environ, &.{ "envee-plugin-env", "metadata" }, "");
    try testing.expectEqual(@as(u8, 0), r.code);
    // Разбирается тем же кодом, что ядро применяет к настоящим плагинам.
    const md = try plugin_mod.parseMetadata(a, r.stdout);
    try testing.expectEqualStrings("env", md.name);
    try testing.expectEqual(api_version, md.api_version);
    try testing.expectEqualStrings("secret", md.capabilities.?[0]);
    try testing.expect(!md.permissions.network);
    try testing.expectEqualStrings("$XDG_DATA_HOME/envee/secrets/env.json", md.permissions.filesystem.?[0]);
}

test "resolve returns the stored value with request id and default TTL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a);
    defer f.tmp.destroy();
    try f.seed(a, &.{.{ "db/password", "hunter2" }});

    const r = try runWith(a, &f.environ, &.{ "envee-plugin-env", "resolve" }, try request(a, 1, "db/password"));
    try testing.expectEqual(@as(u8, 0), r.code);
    const o = try response(a, r.stdout);
    try testing.expectEqualStrings("ok", stringField(o, "status").?);
    try testing.expectEqualStrings("req-1", stringField(o, "request_id").?);
    try testing.expectEqual(@as(i64, 1), o.get("api_version").?.integer);
    try testing.expectEqualStrings("hunter2", stringField(o.get("value").?.object, "value").?);
    try testing.expectEqualStrings("string", stringField(o.get("value").?.object, "type").?);
    const md = o.get("metadata").?.object;
    try testing.expectEqual(ttl_seconds, md.get("ttl_seconds").?.integer);
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", stringField(md, "resolved_at").?);
}

test "structured errors: version mismatch, malformed request, missing ref, unknown key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a);
    defer f.tmp.destroy();

    const mismatch = try runWith(a, &f.environ, &.{ "p", "resolve" }, try request(a, 99, "x"));
    try testing.expectEqual(@as(u8, 1), mismatch.code);
    try testing.expectEqualStrings("version_mismatch", errorCode(try response(a, mismatch.stdout)));

    const malformed = try runWith(a, &f.environ, &.{ "p", "resolve" }, "{not json");
    try testing.expectEqual(@as(u8, 1), malformed.code);
    try testing.expectEqualStrings("invalid_request", errorCode(try response(a, malformed.stdout)));

    const no_ref = try runWith(a, &f.environ, &.{ "p", "resolve" }, "{\"api_version\":1,\"request_id\":\"r\",\"spec\":{}}");
    try testing.expectEqual(@as(u8, 1), no_ref.code);
    const no_ref_o = try response(a, no_ref.stdout);
    try testing.expectEqualStrings("invalid_spec", errorCode(no_ref_o));
    try testing.expectEqualStrings("r", stringField(no_ref_o, "request_id").?);

    // Пустое хранилище: ключа нет — not_found, и ошибка помечена как
    // восстановимая (пользователь может выполнить `envee secret set`).
    const missing = try runWith(a, &f.environ, &.{ "p", "resolve" }, try request(a, 1, "nope"));
    try testing.expectEqual(@as(u8, 1), missing.code);
    const mo = try response(a, missing.stdout);
    try testing.expectEqualStrings("not_found", errorCode(mo));
    try testing.expect(mo.get("error").?.object.get("recoverable").?.bool);
    try testing.expect(std.mem.indexOf(u8, stringField(mo.get("error").?.object, "message").?, "\"nope\"") != null);
}

test "a corrupt store is an internal error, not an empty one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a);
    defer f.tmp.destroy();
    try f.tmp.writeFile(a, "xdg/envee/secrets/env.json", "{\"A\": 1}");

    const r = try runWith(a, &f.environ, &.{ "p", "resolve" }, try request(a, 1, "A"));
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("internal", errorCode(try response(a, r.stdout)));
}

test "unknown or missing subcommands exit with 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a);
    defer f.tmp.destroy();

    try testing.expectEqual(@as(u8, 2), (try runWith(a, &f.environ, &.{ "p", "frobnicate" }, "")).code);
    try testing.expectEqual(@as(u8, 2), (try runWith(a, &f.environ, &.{"p"}, "")).code);
    const v = try runWith(a, &f.environ, &.{ "p", "version" }, "");
    try testing.expectEqual(@as(u8, 0), v.code);
    try testing.expect(std.mem.startsWith(u8, v.stdout, "envee-plugin-env version "));
}

// Сквозная проверка через ядро: собранный бинарь плагина в PATH, секрет
// положен командой `envee secret set`, `eval` его достаёт.
test "the built plugin resolves what `envee secret set` stored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const built = @import("test_options").env_plugin;
    const bin = try Io.Dir.cwd().readFileAlloc(io, built, a, .unlimited);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try tmp.join(a, "envee-plugin-env"), .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });

    const xdg = [2][]const u8{ "XDG_DATA_HOME", try tmp.join(a, "xdg") };
    const path_pair = [2][]const u8{ "PATH", tmp.path };
    _ = try harness.run(a, tmp, &.{ "secret", "set", "DB=hunter2" }, &.{xdg});
    try tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\DB = { source = "env", ref = "DB", redact = true, required = true }
        \\
    );
    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{ xdg, path_pair });
    try testing.expect(std.mem.indexOf(u8, out, "export DB=hunter2;") != null);
}
