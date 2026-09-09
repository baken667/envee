//! `envee secret set|unset|list|get` — локальное хранилище секретов, из
//! которого читает `envee-plugin-env`.
//!
//! Порт `internal/cli/secret.go`. Само хранилище — в `secret_store.zig`,
//! общем с плагином `envee-plugin-env`: файл читают две программы, и
//! договориться о месте и формате они должны буквально.
//!
//! Владение: всё из арены `Ctx`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const Ctx = context.Ctx;

pub const Error = context.Error;

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const name = parsed.command.name;
    if (std.mem.eql(u8, name, "set")) return runSet(ctx, parsed.args[0]);
    if (std.mem.eql(u8, name, "unset")) return runUnset(ctx, parsed.args[0]);
    if (std.mem.eql(u8, name, "list")) return runList(ctx);
    if (std.mem.eql(u8, name, "get")) return runGet(ctx, parsed.args[0]);
    unreachable;
}

const store = @import("../secret_store.zig");
const Secrets = store.Secrets;

fn load(ctx: *Ctx) Error!Secrets {
    const path = try store.path(ctx.arena, ctx.environ);
    return store.load(ctx.arena, ctx.io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return parseFail(path),
        error.ReadFailed => return ioFail(path, "cannot read secret store", err),
    };
}

fn save(ctx: *Ctx, secrets: Secrets) Error!void {
    const path = try store.path(ctx.arena, ctx.environ);
    store.save(ctx.arena, ctx.io, path, secrets) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return ioFail(path, "cannot write secret store", err),
    };
}

fn runSet(ctx: *Ctx, arg: []const u8) Error!void {
    const idx = std.mem.indexOfScalar(u8, arg, '=') orelse 0;
    if (idx == 0) {
        const S = struct {
            var kv: [1]errs.KV = undefined;
        };
        S.kv[0] = .{ .key = "arg", .value = arg };
        return errs.fail(.{
            .code = .e003,
            .summary = "expected KEY=VALUE format",
            .context = &S.kv,
        }, error.ConfigValidation);
    }
    const key = arg[0..idx];
    const value = arg[idx + 1 ..];

    var secrets = try load(ctx);
    try secrets.put(ctx.arena, key, value);
    try save(ctx, secrets);
    try ctx.stderr.print("[envee] set {s}\n", .{key});
}

fn runUnset(ctx: *Ctx, key: []const u8) Error!void {
    var secrets = try load(ctx);
    if (!secrets.swapRemove(key)) return notFound(key);
    try save(ctx, secrets);
    try ctx.stderr.print("[envee] unset {s}\n", .{key});
}

fn runList(ctx: *Ctx) Error!void {
    const secrets = try load(ctx);
    if (secrets.count() == 0) {
        try ctx.stdout.writeAll("(no secrets)\n");
        return;
    }
    // Go перебирает карту в случайном порядке; здесь — по алфавиту, чтобы
    // вывод был стабилен. Значения не печатаются: это список, а не дамп.
    for (try store.sortedKeys(ctx.arena, secrets)) |k| try ctx.stdout.print("{s}=***REDACTED***\n", .{k});
}

fn runGet(ctx: *Ctx, key: []const u8) Error!void {
    const secrets = try load(ctx);
    const v = secrets.get(key) orelse return notFound(key);
    try ctx.stdout.print("{s}={s}\n", .{ key, v });
}

fn notFound(key: []const u8) Error {
    const S = struct {
        var kv: [1]errs.KV = undefined;
    };
    S.kv[0] = .{ .key = "key", .value = key };
    return errs.fail(.{
        .code = .e012,
        .summary = "secret not found",
        .context = &S.kv,
    }, error.FileNotFound);
}

fn parseFail(path: []const u8) Error {
    const S = struct {
        var kv: [1]errs.KV = undefined;
    };
    S.kv[0] = .{ .key = "path", .value = path };
    return errs.fail(.{
        .code = .e002,
        .summary = "secret store is not a JSON object of strings",
        .context = &S.kv,
        .hint = "Fix or remove the file; `envee secret set` will recreate it.",
    }, error.ConfigParse);
}

fn ioFail(path: []const u8, summary: []const u8, err: anyerror) Error {
    const S = struct {
        var kv: [2]errs.KV = undefined;
    };
    S.kv[0] = .{ .key = "path", .value = path };
    S.kv[1] = .{ .key = "detail", .value = @errorName(err) };
    return errs.fail(.{
        .code = .e013,
        .summary = summary,
        .context = &S.kv,
    }, error.PermissionDenied);
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

fn xdgPair(a: Allocator, tmp: harness.TempDir) ![2][]const u8 {
    return .{ "XDG_DATA_HOME", try tmp.join(a, "xdg") };
}

test "set, get, list and unset round-trip through the store file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    const env = try xdgPair(a, tmp);

    try testing.expectEqualStrings("(no secrets)\n", try harness.run(a, tmp, &.{ "secret", "list" }, &.{env}));

    const set = try harness.runFull(a, tmp, &.{ "secret", "set", "DB_PASSWORD=hunter2" }, &.{env}, context.TrustGate.allowAll());
    try testing.expectEqualStrings("[envee] set DB_PASSWORD\n", set.stderr);
    _ = try harness.run(a, tmp, &.{ "secret", "set", "API=a=b" }, &.{env});

    // Значение со знаком равенства делится по первому «=».
    try testing.expectEqualStrings("API=a=b\n", try harness.run(a, tmp, &.{ "secret", "get", "API" }, &.{env}));
    // Список не раскрывает значений.
    try testing.expectEqualStrings("API=***REDACTED***\nDB_PASSWORD=***REDACTED***\n", try harness.run(a, tmp, &.{ "secret", "list" }, &.{env}));

    // Файл — в точности тот, что читает envee-plugin-env: 0600, JSON с
    // отступом в два пробела и ключами по алфавиту.
    const path = try tmp.join(a, "xdg/envee/secrets/env.json");
    const data = try Io.Dir.cwd().readFileAlloc(testing.io, path, a, .unlimited);
    try testing.expectEqualStrings("{\n  \"API\": \"a=b\",\n  \"DB_PASSWORD\": \"hunter2\"\n}", data);
    const st = try Io.Dir.cwd().statFile(testing.io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));

    const unset = try harness.runFull(a, tmp, &.{ "secret", "unset", "API" }, &.{env}, context.TrustGate.allowAll());
    try testing.expectEqualStrings("[envee] unset API\n", unset.stderr);
    try testing.expectEqualStrings("DB_PASSWORD=***REDACTED***\n", try harness.run(a, tmp, &.{ "secret", "list" }, &.{env}));

    // Временных файлов после записи не остаётся.
    var dir = try Io.Dir.cwd().openDir(testing.io, try tmp.join(a, "xdg/envee/secrets"), .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| try testing.expect(std.mem.indexOf(u8, e.name, ".tmp") == null);
}

test "a missing key and a malformed argument are explained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    const env = try xdgPair(a, tmp);

    errs.reset();
    try testing.expectError(error.FileNotFound, harness.run(a, tmp, &.{ "secret", "get", "NOPE" }, &.{env}));
    try testing.expectEqual(errs.Code.e012, errs.take().?.code);

    errs.reset();
    try testing.expectError(error.FileNotFound, harness.run(a, tmp, &.{ "secret", "unset", "NOPE" }, &.{env}));
    try testing.expectEqual(errs.Code.e012, errs.take().?.code);

    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{ "secret", "set", "NOEQUALS" }, &.{env}));
    try testing.expectEqual(errs.Code.e003, errs.take().?.code);
    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{ "secret", "set", "=value" }, &.{env}));
    try testing.expectEqual(errs.Code.e003, errs.take().?.code);
}

test "a corrupt store is an error rather than silently empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    const env = try xdgPair(a, tmp);
    try tmp.writeFile(a, "xdg/envee/secrets/env.json", "{\"A\": 1}");

    errs.reset();
    try testing.expectError(error.ConfigParse, harness.run(a, tmp, &.{ "secret", "list" }, &.{env}));
    try testing.expectEqual(errs.Code.e002, errs.take().?.code);
}
