//! `envee-plugin-infisical`: секреты из Infisical через официальный CLI.
//!
//! Плагин не говорит с API сам: вход в аккаунт, machine identity, выбор
//! инстанса (`.infisical.json`, `INFISICAL_DOMAIN`, `INFISICAL_TOKEN`) —
//! всё это уже умеет `infisical`, и повторять это здесь значило бы
//! разойтись с ним при первом же изменении. Плагин лишь переводит ссылку
//! из `envee.toml` в один вызов `infisical secrets get`.
//!
//! Ссылка: `[env:][/folder/]NAME`.
//!   `DB_PASSWORD`               — секрет в корневой папке
//!   `prod:DB_PASSWORD`          — в окружении `prod`
//!   `/backend/DB_PASSWORD`      — в папке `/backend`
//!   `prod:/backend/DB_PASSWORD` — и то и другое
//!
//! Окружение Infisical, если в ссылке его нет: `INFISICAL_ENV`, иначе
//! активный профиль envee, иначе умолчание CLI (`.infisical.json`). Проект:
//! `INFISICAL_PROJECT_ID`, иначе `.infisical.json` в каталоге конфига.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Environ = std.process.Environ.Map;

const build_options = @import("build_options");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");

pub const name = "infisical";
pub const Input = protocol.Input;

const tool: cli.Tool = .{
    .name = name,
    .cli = "infisical",
    .install_hint = "the infisical CLI is not on $PATH; install it (brew install infisical/get-cli/infisical) and run `infisical login`",
    .timeout_env = "ENVEE_INFISICAL_TIMEOUT_MS",
    .classify = classify,
};

pub fn run(arena: Allocator, io: Io, in: Input, out: *Writer, err_out: *Writer) Allocator.Error!u8 {
    return cli.dispatch(arena, io, in, out, err_out, name, writeMetadata, resolve);
}

fn writeMetadata(out: *Writer) Writer.Error!void {
    try out.writeAll("{\"name\":\"infisical\",\"version\":");
    try std.json.Stringify.value(build_options.version, .{}, out);
    try out.writeAll(",\"api_version\":1,\"description\":\"Infisical secrets through the infisical CLI: ref = [env:][/folder/]NAME\"," ++
        "\"capabilities\":[\"secret\"],\"permissions\":{\"network\":true," ++
        "\"filesystem\":[\".infisical.json\",\"$HOME/.infisical\"],\"exec\":[\"infisical\"]}}\n");
}

// ---- ссылка ------------------------------------------------------------------

pub const Ref = struct {
    /// Окружение Infisical из ссылки; пусто — не задано.
    env: []const u8 = "",
    /// Папка; пусто — умолчание CLI (`/`).
    path: []const u8 = "",
    secret: []const u8,
};

pub const RefError = error{ EmptyName, BadName, BadPath };

/// `[env:][/folder/]NAME`. Двоеточие не встречается в именах секретов и
/// путях Infisical, поэтому первое двоеточие однозначно отделяет окружение.
pub fn parseRef(raw: []const u8) RefError!Ref {
    var rest = raw;
    var r: Ref = .{ .secret = "" };
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        r.env = rest[0..i];
        rest = rest[i + 1 ..];
    }
    if (rest.len > 0 and rest[0] == '/') {
        const last = std.mem.lastIndexOfScalar(u8, rest, '/').?;
        r.path = if (last == 0) "/" else rest[0..last];
        rest = rest[last + 1 ..];
        if (std.mem.indexOf(u8, r.path, "//") != null) return error.BadPath;
    }
    if (rest.len == 0) return error.EmptyName;
    for (rest) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return error.BadName;
    }
    r.secret = rest;
    return r;
}

// ---- resolve -----------------------------------------------------------------

fn resolve(arena: Allocator, io: Io, in: Input, out: *Writer) Allocator.Error!u8 {
    const req = (try protocol.readRequest(arena, out, in.stdin)) orelse return 1;
    if (req.ref.len == 0) {
        try protocol.writeError(arena, out, req.request_id, "invalid_spec", "ref is required: [env:][/folder/]NAME", false);
        return 1;
    }
    const ref = parseRef(req.ref) catch |err| {
        const why = switch (err) {
            error.EmptyName => "secret name is empty",
            error.BadName => "secret name may contain only letters, digits, '_', '-' and '.'",
            error.BadPath => "folder path is malformed",
        };
        try protocol.writeError(arena, out, req.request_id, "invalid_spec", try std.fmt.allocPrint(arena, "ref \"{s}\": {s} (expected [env:][/folder/]NAME)", .{ req.ref, why }), false);
        return 1;
    };

    // Окружение: ссылка > INFISICAL_ENV > профиль envee > умолчание CLI.
    var env_name = ref.env;
    if (env_name.len == 0) env_name = in.environ.get("INFISICAL_ENV") orelse "";
    if (env_name.len == 0) env_name = req.profile;

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "secrets", "get", ref.secret, "--plain", "--silent" });
    if (env_name.len > 0) try args.appendSlice(arena, &.{ "--env", env_name });
    if (ref.path.len > 0) try args.appendSlice(arena, &.{ "--path", ref.path });
    if (in.environ.get("INFISICAL_PROJECT_ID")) |id| if (id.len > 0) {
        try args.appendSlice(arena, &.{ "--projectId", id });
    };

    // CLI ищет `.infisical.json` в рабочем каталоге; у envee это каталог
    // конфига, а не тот, откуда пользователь набрал команду.
    const cwd = if (req.config_root.len > 0) req.config_root else req.cwd;
    const stdout = (try cli.exec(arena, io, in, req, out, tool, args.items, cwd, &.{
        .{ "INFISICAL_DISABLE_UPDATE_CHECK", "true" },
    })) orelse return 1;

    const value = std.mem.trimEnd(u8, stdout, "\n");
    if (value.len == 0) {
        try protocol.writeError(arena, out, req.request_id, "not_found", try std.fmt.allocPrint(arena, "infisical returned no value for \"{s}\"{s}{s}", .{ ref.secret, if (env_name.len > 0) " in environment " else "", env_name }), true);
        return 1;
    }
    try protocol.writeOk(arena, out, req.request_id, value, in.now_ns, "infisical");
    return 0;
}

fn classify(detail: []const u8) cli.Code {
    if (cli.mentions(detail, &.{ "not found", "does not exist", "no secret" })) return .{ .name = "not_found", .recoverable = true };
    if (cli.mentions(detail, &.{ "infisical init", "--projectid", "project id" })) return .{ .name = "no_project", .recoverable = false };
    if (cli.mentions(detail, &.{ "token", "login", "unauthorized", "unauthenticated", "401", "forbidden" })) return .{ .name = "unauthenticated", .recoverable = false };
    return .{ .name = "cli_error", .recoverable = true };
}

// ---- тесты -------------------------------------------------------------------
//
// Поддельный `infisical` — см. `cli.Fixture`.

const testing = std.testing;
const harness = @import("../cli/test_harness.zig");
const plugin_mod = @import("../plugin.zig");

fn fixture(a: Allocator, mode: []const u8) !cli.Fixture {
    return cli.Fixture.create(a, "infisical", fake_script, mode);
}

const fake_script =
    \\#!/bin/sh
    \\printf '%s\n' "$@" > "$FAKE_CLI_ARGS"
    \\printf 'cwd=%s\n' "$PWD" >> "$FAKE_CLI_ARGS"
    \\case "${FAKE_CLI_MODE:-ok}" in
    \\  missing)   echo "error: secret with name $3 not found" >&2; exit 1 ;;
    \\  noauth)    echo "error: invalid service token entered. Please double check your service token and try again" >&2; exit 1 ;;
    \\  noproject) echo "Please either run infisical init to connect to a project or pass in project id with --projectId flag" >&2; exit 1 ;;
    \\  other)     echo "some unexpected failure" >&2; exit 3 ;;
    \\  empty)     exit 0 ;;
    \\  hang)      sleep 60 ;;
    \\  *)         echo "s3cret-value" ;;
    \\esac
    \\
;

test "refs: name, environment and folder in every combination" {
    const cases = [_]struct { raw: []const u8, env: []const u8, path: []const u8, secret: []const u8 }{
        .{ .raw = "DB_PASSWORD", .env = "", .path = "", .secret = "DB_PASSWORD" },
        .{ .raw = "prod:DB_PASSWORD", .env = "prod", .path = "", .secret = "DB_PASSWORD" },
        .{ .raw = "/backend/DB_PASSWORD", .env = "", .path = "/backend", .secret = "DB_PASSWORD" },
        .{ .raw = "/DB_PASSWORD", .env = "", .path = "/", .secret = "DB_PASSWORD" },
        .{ .raw = "prod:/backend/api/DB_PASSWORD", .env = "prod", .path = "/backend/api", .secret = "DB_PASSWORD" },
        .{ .raw = "staging:/x/a.b-c_d", .env = "staging", .path = "/x", .secret = "a.b-c_d" },
    };
    for (cases) |c| {
        const r = try parseRef(c.raw);
        try testing.expectEqualStrings(c.env, r.env);
        try testing.expectEqualStrings(c.path, r.path);
        try testing.expectEqualStrings(c.secret, r.secret);
    }
    try testing.expectError(error.EmptyName, parseRef(""));
    try testing.expectError(error.EmptyName, parseRef("prod:"));
    try testing.expectError(error.EmptyName, parseRef("/backend/"));
    try testing.expectError(error.BadName, parseRef("DB PASSWORD"));
    try testing.expectError(error.BadName, parseRef("a:b:c"));
    try testing.expectError(error.BadPath, parseRef("//x/NAME"));
}

test "metadata declares network and the infisical executable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: Environ = .init(a);
    var out: Writer.Allocating = .init(a);
    var err_out: Writer.Allocating = .init(a);
    try testing.expectEqual(@as(u8, 0), try run(a, testing.io, .{ .argv = &.{ "p", "metadata" }, .stdin = "", .environ = &environ, .now_ns = 0 }, &out.writer, &err_out.writer));
    const md = try plugin_mod.parseMetadata(a, out.written());
    try testing.expectEqualStrings("infisical", md.name);
    try testing.expect(md.permissions.network);
    try testing.expectEqualStrings("infisical", md.permissions.exec.?[0]);
}

test "resolve builds the CLI call from the ref and the envee profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    const r = try f.resolveWith(a, run, "/backend/DB_PASSWORD", "prod");
    try testing.expectEqual(@as(u8, 0), r.code);
    const o = try cli.response(a, r.stdout);
    try testing.expectEqualStrings("ok", protocol.stringField(o, "status").?);
    try testing.expectEqualStrings("s3cret-value", protocol.stringField(o.get("value").?.object, "value").?);
    try testing.expectEqualStrings("infisical", protocol.stringField(o.get("metadata").?.object, "source").?);

    // Профиль envee стал окружением Infisical, папка — --path, cwd — каталог конфига.
    const args = try f.recordedArgs(a);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "secrets\nget\nDB_PASSWORD\n--plain\n--silent\n--env\nprod\n--path\n/backend\ncwd={s}\n", .{f.tmp.path}), args);
}

test "the Infisical environment: ref wins over INFISICAL_ENV, which wins over the profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a, "");
    defer f.destroy();

    // Ни ссылки, ни переменной, ни профиля — флаг не передаётся вовсе, и
    // окружение выбирает сам CLI по .infisical.json.
    _ = try f.resolveWith(a, run, "TOKEN", "");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env") == null);

    try f.environ.put("INFISICAL_ENV", "staging");
    _ = try f.resolveWith(a, run, "TOKEN", "dev");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nstaging\n") != null);

    _ = try f.resolveWith(a, run, "production:TOKEN", "dev");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nproduction\n") != null);

    try f.environ.put("INFISICAL_PROJECT_ID", "proj-123");
    _ = try f.resolveWith(a, run, "TOKEN", "");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--projectId\nproj-123\n") != null);
}

test "CLI failures become structured errors with the CLI's own words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { mode: []const u8, code: []const u8, recoverable: bool, contains: []const u8 }{
        .{ .mode = "missing", .code = "not_found", .recoverable = true, .contains = "secret with name NOPE not found" },
        .{ .mode = "noauth", .code = "unauthenticated", .recoverable = false, .contains = "invalid service token" },
        .{ .mode = "noproject", .code = "no_project", .recoverable = false, .contains = "infisical init" },
        .{ .mode = "other", .code = "cli_error", .recoverable = true, .contains = "some unexpected failure" },
        .{ .mode = "empty", .code = "not_found", .recoverable = true, .contains = "returned no value for \"NOPE\"" },
    };
    for (cases) |c| {
        const f = try fixture(a, c.mode);
        defer f.destroy();
        const r = try f.resolveWith(a, run, "NOPE", "");
        try testing.expectEqual(@as(u8, 1), r.code);
        const o = try cli.response(a, r.stdout);
        try testing.expectEqualStrings(c.code, cli.errorCode(o));
        try testing.expectEqual(c.recoverable, o.get("error").?.object.get("recoverable").?.bool);
        try testing.expect(std.mem.indexOf(u8, protocol.stringField(o.get("error").?.object, "message").?, c.contains) != null);
    }
}

test "a missing CLI, a hanging CLI and a bad ref are explained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f = try fixture(a, "");
    defer f.destroy();
    const bad = try f.resolveWith(a, run, "no spaces allowed", "");
    try testing.expectEqualStrings("invalid_spec", cli.errorCode(try cli.response(a, bad.stdout)));

    try f.environ.put("PATH", "/nonexistent");
    const gone = try f.resolveWith(a, run, "TOKEN", "");
    const go = try cli.response(a, gone.stdout);
    try testing.expectEqualStrings("not_installed", cli.errorCode(go));
    try testing.expect(std.mem.indexOf(u8, protocol.stringField(go.get("error").?.object, "message").?, "brew install") != null);

    var h = try fixture(a, "hang");
    defer h.destroy();
    try h.environ.put("ENVEE_INFISICAL_TIMEOUT_MS", "300");
    const slow = try h.resolveWith(a, run, "TOKEN", "");
    try testing.expectEqualStrings("timeout", cli.errorCode(try cli.response(a, slow.stdout)));
}

// Сквозная проверка: собранный плагин в PATH рядом с поддельным CLI,
// конфиг ссылается на источник infisical, eval получает значение.
test "the built plugin resolves an Infisical secret through the core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, "");
    defer f.destroy();

    try f.installPlugin(a, name, @import("test_options").infisical_plugin);
    try f.tmp.write(a,
        \\schema = "envee/v1"
        \\profile = "prod"
        \\[env]
        \\DB_PASSWORD = { source = "infisical", ref = "/backend/DB_PASSWORD", redact = true, required = true }
        \\
    );
    const pairs = [_][2][]const u8{
        .{ "PATH", f.environ.get("PATH").? },
        .{ "FAKE_CLI_ARGS", f.args_file },
    };
    const out = try harness.run(a, f.tmp, &.{ "eval", "bash" }, &pairs);
    try testing.expect(std.mem.indexOf(u8, out, "export DB_PASSWORD=s3cret-value;") != null);
    // Профиль из конфига дошёл до CLI как окружение Infisical.
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nprod\n") != null);
}
