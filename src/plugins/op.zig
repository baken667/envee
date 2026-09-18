//! `envee-plugin-op`: секреты из 1Password через официальный CLI `op`.
//!
//! Ссылка — секретная ссылка 1Password, та же, что у `op read`:
//!   `op://vault/item/field`
//!   `op://vault/item/section/field`
//!   `vault/item/field`              — префикс `op://` можно опустить
//!
//! Вход, аккаунт (`OP_ACCOUNT`), сервисный токен (`OP_SERVICE_ACCOUNT_TOKEN`)
//! и интеграция с приложением 1Password — забота `op`; плагин передаёт ему
//! окружение как есть.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const build_options = @import("build_options");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");

pub const name = "op";

const tool: cli.Tool = .{
    .name = name,
    .cli = "op",
    .install_hint = "the 1Password CLI (op) is not on $PATH; install it (brew install 1password-cli) and sign in with `op signin`",
    .timeout_env = "ENVEE_OP_TIMEOUT_MS",
    .classify = classify,
};

pub fn run(arena: Allocator, io: Io, in: cli.Input, out: *Writer, err_out: *Writer) Allocator.Error!u8 {
    return cli.dispatch(arena, io, in, out, err_out, name, writeMetadata, resolve);
}

fn writeMetadata(out: *Writer) Writer.Error!void {
    try out.writeAll("{\"name\":\"op\",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, out);
    try out.writeAll(",\"api_version\":1,\"description\":\"1Password through the op CLI: ref = op://vault/item/[section/]field\"," ++
        "\"capabilities\":[\"secret\"],\"permissions\":{\"network\":true," ++
        "\"filesystem\":[\"$HOME/.config/op\"],\"exec\":[\"op\"]}}\n");
}

/// Приводит ссылку к `op://vault/item/[section/]field`. `null` — ссылка не
/// той формы: `op` сам бы её отверг, но с менее понятным сообщением.
pub fn normalizeRef(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const body = if (std.mem.startsWith(u8, raw, "op://")) raw["op://".len..] else raw;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |p| {
        if (p.len == 0) return null;
        parts += 1;
    }
    if (parts < 3 or parts > 4) return null;
    return try std.fmt.allocPrint(arena, "op://{s}", .{body});
}

fn resolve(arena: Allocator, io: Io, in: cli.Input, out: *Writer) Allocator.Error!u8 {
    const req = (try protocol.readRequest(arena, out, in.stdin)) orelse return 1;
    const ref = (try normalizeRef(arena, req.ref)) orelse {
        try protocol.writeError(arena, out, req.request_id, "invalid_spec", try std.fmt.allocPrint(arena, "ref \"{s}\" is not a 1Password secret reference (expected op://vault/item/[section/]field)", .{req.ref}), false);
        return 1;
    };

    // --no-newline: значение уходит как есть, без перевода строки в конце,
    // который пришлось бы угадывать — отрезать его или он часть секрета.
    const stdout = (try cli.exec(arena, io, in, req, out, tool, &.{ "read", "--no-newline", ref }, req.config_root, &.{})) orelse return 1;
    try protocol.writeOk(arena, out, req.request_id, stdout, in.now_ns, name);
    return 0;
}

fn classify(detail: []const u8) cli.Code {
    if (cli.mentions(detail, &.{ "isn't an item", "isn't a vault", "isn't a field", "could not find", "no item found", "not found" })) return .{ .name = "not_found", .recoverable = true };
    if (cli.mentions(detail, &.{ "not currently signed in", "no accounts configured", "signin", "sign in", "session expired", "authorization", "unauthorized", "401", "403" })) return .{ .name = "unauthenticated", .recoverable = false };
    return .{ .name = "cli_error", .recoverable = true };
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("../cli/test_harness.zig");
const plugin_mod = @import("../plugin.zig");

const fake_script =
    \\#!/bin/sh
    \\printf '%s\n' "$@" > "$FAKE_CLI_ARGS"
    \\case "${FAKE_CLI_MODE:-ok}" in
    \\  missing) echo '[ERROR] 2026/09/18 10:00:00 "nope" isn'"'"'t an item in the "Dev" vault. Specify the item with its UUID, name, or domain.' >&2; exit 1 ;;
    \\  noauth)  echo '[ERROR] 2026/09/18 10:00:00 You are not currently signed in. Please run `op signin --help` for instructions' >&2; exit 1 ;;
    \\  *)       printf 'line one\nline two\n' ;;
    \\esac
    \\
;

fn fixture(a: Allocator, mode: []const u8) !cli.Fixture {
    return cli.Fixture.create(a, "op", fake_script, mode);
}

test "refs are normalized to op:// with vault, item, optional section and field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("op://Dev/db/password", (try normalizeRef(a, "op://Dev/db/password")).?);
    try testing.expectEqualStrings("op://Dev/db/password", (try normalizeRef(a, "Dev/db/password")).?);
    try testing.expectEqualStrings("op://Dev/db/admin/password", (try normalizeRef(a, "Dev/db/admin/password")).?);
    try testing.expect((try normalizeRef(a, "Dev/db")) == null);
    try testing.expect((try normalizeRef(a, "op://Dev//password")) == null);
    try testing.expect((try normalizeRef(a, "a/b/c/d/e")) == null);
    try testing.expect((try normalizeRef(a, "")) == null);
}

test "metadata declares network and the op executable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(a);
    var out: Writer.Allocating = .init(a);
    var err_out: Writer.Allocating = .init(a);
    try testing.expectEqual(@as(u8, 0), try run(a, testing.io, .{ .argv = &.{ "p", "metadata" }, .stdin = "", .environ = &environ, .now_ns = 0 }, &out.writer, &err_out.writer));
    const md = try plugin_mod.parseMetadata(a, out.written());
    try testing.expectEqualStrings("op", md.name);
    try testing.expectEqualStrings("op", md.permissions.exec.?[0]);
}

test "resolve reads the reference and keeps the value byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    const r = try f.resolveWith(a, run, "Dev/db/password", "");
    try testing.expectEqual(@as(u8, 0), r.code);
    const o = try cli.response(a, r.stdout);
    try testing.expectEqualStrings("line one\nline two\n", cli.okValue(o));
    try testing.expectEqualStrings("read\n--no-newline\nop://Dev/db/password\n", try f.recordedArgs(a));
}

test "op failures become structured errors with op's own words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { mode: []const u8, code: []const u8, contains: []const u8 }{
        .{ .mode = "missing", .code = "not_found", .contains = "isn't an item" },
        .{ .mode = "noauth", .code = "unauthenticated", .contains = "not currently signed in" },
    };
    for (cases) |c| {
        const f = try fixture(a, c.mode);
        defer f.destroy();
        const o = try cli.response(a, (try f.resolveWith(a, run, "op://Dev/nope/password", "")).stdout);
        try testing.expectEqualStrings(c.code, cli.errorCode(o));
        try testing.expect(std.mem.indexOf(u8, cli.errorMessage(o), c.contains) != null);
    }

    var f = try fixture(a, "");
    defer f.destroy();
    try testing.expectEqualStrings("invalid_spec", cli.errorCode(try cli.response(a, (try f.resolveWith(a, run, "just-a-name", "")).stdout)));
    try f.environ.put("PATH", "/nonexistent");
    try testing.expectEqualStrings("not_installed", cli.errorCode(try cli.response(a, (try f.resolveWith(a, run, "Dev/db/password", "")).stdout)));
}

test "the built plugin resolves a 1Password secret through the core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    try f.installPlugin(a, name, @import("test_options").op_plugin);
    try f.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\DB_PASSWORD = { source = "op", ref = "op://Dev/db/password", redact = true }
        \\
    );
    const pairs = [_][2][]const u8{
        .{ "PATH", f.environ.get("PATH").? },
        .{ "FAKE_CLI_ARGS", f.args_file },
    };
    const out = try harness.run(a, f.tmp, &.{"resolve"}, &pairs);
    try testing.expect(std.mem.indexOf(u8, out, "DB_PASSWORD=") != null);
    try testing.expectEqualStrings("read\n--no-newline\nop://Dev/db/password\n", try f.recordedArgs(a));
}
