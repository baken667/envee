//! `envee-plugin-sops`: значения из файлов, зашифрованных SOPS.
//!
//! Ссылка: `FILE#KEY[.KEY...]` — путь к файлу относительно каталога
//! конфига и путь к значению внутри него:
//!   `secrets.enc.yaml#db.password`  → `sops --decrypt --extract '["db"]["password"]' secrets.enc.yaml`
//!
//! Ключи (age, PGP, KMS, Vault) ищет сам `sops` — по `SOPS_AGE_KEY_FILE`,
//! `.sops.yaml`, профилям облаков; плагин передаёт ему окружение как есть.
//! Файл целиком одной переменной не бывает, поэтому ключ обязателен.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const build_options = @import("build_options");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");

pub const name = "sops";

const tool: cli.Tool = .{
    .name = name,
    .cli = "sops",
    .install_hint = "sops is not on $PATH; install it (brew install sops)",
    .timeout_env = "ENVEE_SOPS_TIMEOUT_MS",
    .classify = classify,
};

pub fn run(arena: Allocator, io: Io, in: cli.Input, out: *Writer, err_out: *Writer) Allocator.Error!u8 {
    return cli.dispatch(arena, io, in, out, err_out, name, writeMetadata, resolve);
}

fn writeMetadata(out: *Writer) Writer.Error!void {
    try out.writeAll("{\"name\":\"sops\",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, out);
    try out.writeAll(",\"api_version\":1,\"description\":\"SOPS-encrypted files through the sops CLI: ref = FILE#KEY[.KEY...]\"," ++
        "\"capabilities\":[\"secret\"],\"permissions\":{\"network\":true," ++
        "\"filesystem\":[\"$CONFIG_ROOT\",\"$HOME/.config/sops\"],\"exec\":[\"sops\"]}}\n");
}

pub const Ref = struct {
    file: []const u8,
    /// Выражение для `--extract`: `["db"]["password"]`.
    extract: []const u8,
};

/// `FILE#a.b` → файл и `["a"]["b"]`. `null` — нет файла, нет ключа, пустой
/// сегмент или кавычка в ключе, которая сломала бы выражение.
pub fn parseRef(arena: Allocator, raw: []const u8) Allocator.Error!?Ref {
    const hash = std.mem.lastIndexOfScalar(u8, raw, '#') orelse return null;
    const file = raw[0..hash];
    const key = raw[hash + 1 ..];
    if (file.len == 0 or key.len == 0) return null;

    var extract: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.indexOfAny(u8, seg, "\"\\") != null) return null;
        try extract.print(arena, "[\"{s}\"]", .{seg});
    }
    return .{ .file = file, .extract = try extract.toOwnedSlice(arena) };
}

fn resolve(arena: Allocator, io: Io, in: cli.Input, out: *Writer) Allocator.Error!u8 {
    const req = (try protocol.readRequest(arena, out, in.stdin)) orelse return 1;
    const ref = (try parseRef(arena, req.ref)) orelse {
        try protocol.writeError(arena, out, req.request_id, "invalid_spec", try std.fmt.allocPrint(arena, "ref \"{s}\" must name a file and a key: FILE#KEY[.KEY...]", .{req.ref}), false);
        return 1;
    };

    // Относительный путь — от каталога конфига, как у `_.file`; туда же
    // ставится cwd, чтобы sops нашёл `.sops.yaml` проекта.
    const cwd = if (req.config_root.len > 0) req.config_root else req.cwd;
    const stdout = (try cli.exec(arena, io, in, req, out, tool, &.{ "--decrypt", "--extract", ref.extract, ref.file }, cwd, &.{})) orelse return 1;

    // Строковое значение sops печатает с переводом строки в конце, которого
    // в самом значении нет.
    const value = if (std.mem.endsWith(u8, stdout, "\n")) stdout[0 .. stdout.len - 1] else stdout;
    try protocol.writeOk(arena, out, req.request_id, value, in.now_ns, name);
    return 0;
}

fn classify(detail: []const u8) cli.Code {
    if (cli.mentions(detail, &.{ "not found", "no such file", "non-existent file", "does not exist" })) return .{ .name = "not_found", .recoverable = true };
    if (cli.mentions(detail, &.{ "data key", "could not decrypt", "no identity matched", "error decrypting key", "failed to decrypt", "access denied" })) return .{ .name = "unauthenticated", .recoverable = false };
    return .{ .name = "cli_error", .recoverable = true };
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("../cli/test_harness.zig");
const plugin_mod = @import("../plugin.zig");

const fake_script =
    \\#!/bin/sh
    \\printf '%s\n' "$@" > "$FAKE_CLI_ARGS"
    \\printf 'cwd=%s\n' "$PWD" >> "$FAKE_CLI_ARGS"
    \\case "${FAKE_CLI_MODE:-ok}" in
    \\  missing) echo "component ['nope'] not found" >&2; exit 1 ;;
    \\  nokey)   printf 'Failed to get the data key required to decrypt the SOPS file.\n\nGroup 0: FAILED\n' >&2; exit 128 ;;
    \\  *)       echo "hunter2" ;;
    \\esac
    \\
;

fn fixture(a: Allocator, mode: []const u8) !cli.Fixture {
    return cli.Fixture.create(a, "sops", fake_script, mode);
}

test "refs split into a file and an --extract expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try parseRef(a, "secrets/prod.enc.yaml#db.password")).?;
    try testing.expectEqualStrings("secrets/prod.enc.yaml", r.file);
    try testing.expectEqualStrings("[\"db\"][\"password\"]", r.extract);
    try testing.expectEqualStrings("[\"TOKEN\"]", (try parseRef(a, "s.json#TOKEN")).?.extract);
    try testing.expect((try parseRef(a, "secrets.yaml")) == null);
    try testing.expect((try parseRef(a, "#key")) == null);
    try testing.expect((try parseRef(a, "s.yaml#")) == null);
    try testing.expect((try parseRef(a, "s.yaml#a..b")) == null);
    try testing.expect((try parseRef(a, "s.yaml#a\"]")) == null);
}

test "metadata declares the sops executable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(a);
    var out: Writer.Allocating = .init(a);
    var err_out: Writer.Allocating = .init(a);
    try testing.expectEqual(@as(u8, 0), try run(a, testing.io, .{ .argv = &.{ "p", "metadata" }, .stdin = "", .environ = &environ, .now_ns = 0 }, &out.writer, &err_out.writer));
    const md = try plugin_mod.parseMetadata(a, out.written());
    try testing.expectEqualStrings("sops", md.name);
    try testing.expectEqualStrings("sops", md.permissions.exec.?[0]);
}

test "resolve decrypts one key in the config directory and drops the trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    const r = try f.resolveWith(a, run, "secrets.enc.yaml#db.password", "");
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("hunter2", cli.okValue(try cli.response(a, r.stdout)));
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "--decrypt\n--extract\n[\"db\"][\"password\"]\nsecrets.enc.yaml\ncwd={s}\n", .{f.tmp.path}),
        try f.recordedArgs(a),
    );
}

test "sops failures become structured errors with sops's own words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { mode: []const u8, code: []const u8, contains: []const u8 }{
        .{ .mode = "missing", .code = "not_found", .contains = "component ['nope'] not found" },
        .{ .mode = "nokey", .code = "unauthenticated", .contains = "data key" },
    };
    for (cases) |c| {
        const f = try fixture(a, c.mode);
        defer f.destroy();
        const o = try cli.response(a, (try f.resolveWith(a, run, "s.yaml#nope", "")).stdout);
        try testing.expectEqualStrings(c.code, cli.errorCode(o));
        try testing.expect(std.mem.indexOf(u8, cli.errorMessage(o), c.contains) != null);
    }

    var f = try fixture(a, "");
    defer f.destroy();
    try testing.expectEqualStrings("invalid_spec", cli.errorCode(try cli.response(a, (try f.resolveWith(a, run, "no-key.yaml", "")).stdout)));
    try f.environ.put("PATH", "/nonexistent");
    try testing.expectEqualStrings("not_installed", cli.errorCode(try cli.response(a, (try f.resolveWith(a, run, "s.yaml#k", "")).stdout)));
}

test "the built plugin resolves a SOPS value through the core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    try f.installPlugin(a, name, @import("test_options").sops_plugin);
    try f.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\DB_PASSWORD = { source = "sops", ref = "secrets.enc.yaml#db.password" }
        \\
    );
    const pairs = [_][2][]const u8{
        .{ "PATH", f.environ.get("PATH").? },
        .{ "FAKE_CLI_ARGS", f.args_file },
    };
    const out = try harness.run(a, f.tmp, &.{ "eval", "bash" }, &pairs);
    try testing.expect(std.mem.indexOf(u8, out, "export DB_PASSWORD=hunter2;") != null);
}
