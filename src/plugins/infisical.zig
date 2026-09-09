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
const protocol = @import("protocol.zig");
const core_plugin = @import("../plugin.zig");

pub const name = "infisical";
pub const cli = "infisical";
/// Ядро убивает плагин через 10 с; CLI получает меньше, чтобы ответ с
/// объяснением успел дойти.
pub const default_timeout_ms: i64 = 8_000;
pub const Input = protocol.Input;

pub fn run(arena: Allocator, io: Io, in: Input, out: *Writer, err_out: *Writer) Allocator.Error!u8 {
    if (in.argv.len < 2) {
        err_out.writeAll("usage: envee-plugin-infisical <metadata|resolve|version>\n") catch {};
        return 2;
    }
    const sub = in.argv[1];
    if (std.mem.eql(u8, sub, "metadata")) {
        writeMetadata(out) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "version")) {
        out.print("envee-plugin-infisical version {s}\n", .{build_options.version}) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "resolve")) return resolve(arena, io, in, out);
    err_out.print("unknown subcommand: {s}\n", .{sub}) catch {};
    return 2;
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

    // CLI ищется по PATH из окружения запроса, а не процесса: spawn
    // разрешает argv[0] по окружению родителя, и подменить его (в тестах
    // или через `env PATH=...`) иначе нельзя.
    const cli_path = (try core_plugin.lookPath(arena, io, in.environ.get("PATH") orelse "", cli)) orelse {
        try protocol.writeError(arena, out, req.request_id, "not_installed", "the infisical CLI is not on $PATH; install it (brew install infisical/get-cli/infisical) and run `infisical login`", false);
        return 1;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ cli_path, "secrets", "get", ref.secret, "--plain", "--silent" });
    if (env_name.len > 0) try argv.appendSlice(arena, &.{ "--env", env_name });
    if (ref.path.len > 0) try argv.appendSlice(arena, &.{ "--path", ref.path });
    if (in.environ.get("INFISICAL_PROJECT_ID")) |id| if (id.len > 0) {
        try argv.appendSlice(arena, &.{ "--projectId", id });
    };

    // CLI ищет `.infisical.json` в рабочем каталоге; у envee это каталог
    // конфига, а не тот, откуда пользователь набрал команду.
    const cwd = if (req.config_root.len > 0) req.config_root else req.cwd;

    var environ = try in.environ.clone(arena);
    try environ.put("INFISICAL_DISABLE_UPDATE_CHECK", "true");
    try environ.put("NO_COLOR", "1");

    const timeout_ms: i64 = blk: {
        const raw = in.environ.get("ENVEE_INFISICAL_TIMEOUT_MS") orelse break :blk default_timeout_ms;
        break :blk std.fmt.parseInt(i64, raw, 10) catch default_timeout_ms;
    };

    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .environ_map = &environ,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            try protocol.writeError(arena, out, req.request_id, "not_installed", "the infisical CLI is not on $PATH; install it (brew install infisical/get-cli/infisical) and run `infisical login`", false);
            return 1;
        },
        error.Timeout => {
            try protocol.writeError(arena, out, req.request_id, "timeout", try std.fmt.allocPrint(arena, "infisical did not answer within {d} ms", .{timeout_ms}), true);
            return 1;
        },
        else => {
            try protocol.writeError(arena, out, req.request_id, "internal", try std.fmt.allocPrint(arena, "cannot run infisical: {s}", .{@errorName(err)}), true);
            return 1;
        },
    };

    const failed = result.term != .exited or result.term.exited != 0;
    if (failed) {
        const detail = firstLine(result.stderr);
        const code = classify(detail);
        const message = if (detail.len > 0)
            try std.fmt.allocPrint(arena, "infisical: {s}", .{detail})
        else
            try std.fmt.allocPrint(arena, "infisical exited with {s}", .{termName(arena, result.term)});
        try protocol.writeError(arena, out, req.request_id, code.name, message, code.recoverable);
        return 1;
    }

    const value = std.mem.trimEnd(u8, result.stdout, "\n");
    if (value.len == 0) {
        try protocol.writeError(arena, out, req.request_id, "not_found", try std.fmt.allocPrint(arena, "infisical returned no value for \"{s}\"{s}{s}", .{ ref.secret, if (env_name.len > 0) " in environment " else "", env_name }), true);
        return 1;
    }
    try protocol.writeOk(arena, out, req.request_id, value, in.now_ns, "infisical");
    return 0;
}

const Code = struct { name: []const u8, recoverable: bool };

/// Код ошибки по тексту CLI. Точные формулировки CLI не документированы и
/// меняются, поэтому классификация по ключевым словам, а сам текст всегда
/// уходит пользователю целиком.
fn classify(detail: []const u8) Code {
    var lower_buf: [512]u8 = undefined;
    const n = @min(detail.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], detail[0..n]);
    if (contains(lower, "not found") or contains(lower, "does not exist") or contains(lower, "no secret")) return .{ .name = "not_found", .recoverable = true };
    if (contains(lower, "infisical init") or contains(lower, "--projectid") or contains(lower, "project id")) return .{ .name = "no_project", .recoverable = false };
    if (contains(lower, "token") or contains(lower, "login") or contains(lower, "unauthorized") or contains(lower, "unauthenticated") or contains(lower, "401") or contains(lower, "forbidden")) return .{ .name = "unauthenticated", .recoverable = false };
    return .{ .name = "cli_error", .recoverable = true };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn firstLine(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}

fn termName(arena: Allocator, term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |c| std.fmt.allocPrint(arena, "status {d}", .{c}) catch "status ?",
        .signal => |s| std.fmt.allocPrint(arena, "signal {d}", .{@intFromEnum(s)}) catch "signal",
        else => @tagName(term),
    };
}

// ---- тесты -------------------------------------------------------------------
//
// Настоящий CLI в тестах не участвует: поддельный `infisical` — скрипт в
// временном каталоге, который записывает свои аргументы и ведёт себя по
// `FAKE_INFISICAL_MODE`. Так проверяется ровно то, за что отвечает плагин:
// какую команду он собирает и как переводит ответы.

const testing = std.testing;
const harness = @import("../cli/test_harness.zig");
const plugin_mod = @import("../plugin.zig");
const perms = @import("../perms.zig");

const fake_script =
    \\#!/bin/sh
    \\printf '%s\n' "$@" > "$FAKE_INFISICAL_ARGS"
    \\printf 'cwd=%s\n' "$PWD" >> "$FAKE_INFISICAL_ARGS"
    \\case "${FAKE_INFISICAL_MODE:-ok}" in
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

const Fixture = struct {
    tmp: harness.TempDir,
    environ: Environ,
    args_file: []const u8,

    fn create(a: Allocator, mode: []const u8) !Fixture {
        const tmp = try harness.TempDir.create(a);
        const bin_dir = try tmp.join(a, "bin");
        try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try tmp.join(a, "bin/infisical"), .data = fake_script, .flags = .{ .permissions = perms.fromMode(0o755) } });
        const args_file = try tmp.join(a, "args.txt");
        var environ: Environ = .init(a);
        try environ.put("PATH", try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{bin_dir}));
        try environ.put("HOME", tmp.path);
        try environ.put("FAKE_INFISICAL_ARGS", args_file);
        if (mode.len > 0) try environ.put("FAKE_INFISICAL_MODE", mode);
        return .{ .tmp = tmp, .environ = environ, .args_file = args_file };
    }

    fn destroy(f: Fixture) void {
        f.tmp.destroy();
    }

    fn resolveWith(f: *const Fixture, a: Allocator, ref: []const u8, profile: []const u8) !Run {
        const body = try std.fmt.allocPrint(a, "{{\"api_version\":1,\"request_id\":\"req-1\",\"spec\":{{\"ref\":\"{s}\"}},\"context\":{{\"config_root\":\"{s}\",\"cwd\":\"{s}\",\"profile\":\"{s}\",\"env\":{{}}}}}}", .{ ref, f.tmp.path, f.tmp.path, profile });
        var out: Writer.Allocating = .init(a);
        var err_out: Writer.Allocating = .init(a);
        const code = try run(a, testing.io, .{ .argv = &.{ "p", "resolve" }, .stdin = body, .environ = &f.environ, .now_ns = 0 }, &out.writer, &err_out.writer);
        return .{ .code = code, .stdout = out.written() };
    }

    fn recordedArgs(f: *const Fixture, a: Allocator) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, f.args_file, a, .unlimited);
    }
};

const Run = struct { code: u8, stdout: []const u8 };

fn response(a: Allocator, stdout: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, stdout, .{});
    try testing.expect(v == .object);
    return v.object;
}

fn errorCode(o: std.json.ObjectMap) []const u8 {
    return protocol.stringField(o.get("error").?.object, "code").?;
}

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
    const f = try Fixture.create(a, "");
    defer f.destroy();

    const r = try f.resolveWith(a, "/backend/DB_PASSWORD", "prod");
    try testing.expectEqual(@as(u8, 0), r.code);
    const o = try response(a, r.stdout);
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
    var f = try Fixture.create(a, "");
    defer f.destroy();

    // Ни ссылки, ни переменной, ни профиля — флаг не передаётся вовсе, и
    // окружение выбирает сам CLI по .infisical.json.
    _ = try f.resolveWith(a, "TOKEN", "");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env") == null);

    try f.environ.put("INFISICAL_ENV", "staging");
    _ = try f.resolveWith(a, "TOKEN", "dev");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nstaging\n") != null);

    _ = try f.resolveWith(a, "production:TOKEN", "dev");
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nproduction\n") != null);

    try f.environ.put("INFISICAL_PROJECT_ID", "proj-123");
    _ = try f.resolveWith(a, "TOKEN", "");
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
        const f = try Fixture.create(a, c.mode);
        defer f.destroy();
        const r = try f.resolveWith(a, "NOPE", "");
        try testing.expectEqual(@as(u8, 1), r.code);
        const o = try response(a, r.stdout);
        try testing.expectEqualStrings(c.code, errorCode(o));
        try testing.expectEqual(c.recoverable, o.get("error").?.object.get("recoverable").?.bool);
        try testing.expect(std.mem.indexOf(u8, protocol.stringField(o.get("error").?.object, "message").?, c.contains) != null);
    }
}

test "a missing CLI, a hanging CLI and a bad ref are explained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f = try Fixture.create(a, "");
    defer f.destroy();
    const bad = try f.resolveWith(a, "no spaces allowed", "");
    try testing.expectEqualStrings("invalid_spec", errorCode(try response(a, bad.stdout)));

    try f.environ.put("PATH", "/nonexistent");
    const gone = try f.resolveWith(a, "TOKEN", "");
    const go = try response(a, gone.stdout);
    try testing.expectEqualStrings("not_installed", errorCode(go));
    try testing.expect(std.mem.indexOf(u8, protocol.stringField(go.get("error").?.object, "message").?, "brew install") != null);

    var h = try Fixture.create(a, "hang");
    defer h.destroy();
    try h.environ.put("ENVEE_INFISICAL_TIMEOUT_MS", "300");
    const slow = try h.resolveWith(a, "TOKEN", "");
    try testing.expectEqualStrings("timeout", errorCode(try response(a, slow.stdout)));
}

// Сквозная проверка: собранный плагин в PATH рядом с поддельным CLI,
// конфиг ссылается на источник infisical, eval получает значение.
test "the built plugin resolves an Infisical secret through the core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const f = try Fixture.create(a, "");
    defer f.destroy();

    const built = @import("test_options").infisical_plugin;
    const bin = try Io.Dir.cwd().readFileAlloc(io, built, a, .unlimited);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try f.tmp.join(a, "bin/envee-plugin-infisical"), .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });
    try f.tmp.write(a,
        \\schema = "envee/v1"
        \\profile = "prod"
        \\[env]
        \\DB_PASSWORD = { source = "infisical", ref = "/backend/DB_PASSWORD", redact = true, required = true }
        \\
    );
    const pairs = [_][2][]const u8{
        .{ "PATH", f.environ.get("PATH").? },
        .{ "FAKE_INFISICAL_ARGS", f.args_file },
    };
    const out = try harness.run(a, f.tmp, &.{ "eval", "bash" }, &pairs);
    try testing.expect(std.mem.indexOf(u8, out, "export DB_PASSWORD=s3cret-value;") != null);
    // Профиль из конфига дошёл до CLI как окружение Infisical.
    try testing.expect(std.mem.indexOf(u8, try f.recordedArgs(a), "--env\nprod\n") != null);
}
