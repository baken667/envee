//! `envee exec -- <command> [args...]`: запуск команды с применённым
//! окружением, без hook'а оболочки.
//!
//! Порт `internal/cli/exec.go`. Отличие в разборе: Go отключал разбор флагов
//! и искал `--` руками, здесь общий парсер сам знает, что после `--` идёт
//! чужая команда, так что `--profile` и прочие флаги работают как везде.

const std = @import("std");
const Allocator = std.mem.Allocator;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const plugin = @import("../plugin.zig");
const Ctx = context.Ctx;

pub const Error = context.Error;

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const child_argv = parsed.args;
    if (child_argv.len == 0) {
        return errs.fail(.{
            .code = .e003,
            .summary = "missing command",
            .hint = "Usage: envee exec -- <command> [args...]",
        }, error.ConfigValidation);
    }

    // Проверка доверия — внутри resolveEnv, до применения директив.
    const r = try context.resolveEnv(ctx, parsed.str("profile"), stop_at);

    // Окружение ребёнка: окружение процесса, поверх — вычисленное.
    var environ = try ctx.environ.clone(ctx.arena);
    for (r.result.env.entries.items) |e| try environ.put(e.key, e.value);

    const bin = try lookup(ctx, child_argv[0]);
    var argv = try ctx.arena.dupe([]const u8, child_argv);
    argv[0] = bin;

    // Потоки наследуются: команда должна видеть терминал так, будто её
    // запустили напрямую.
    ctx.stdout.flush() catch {};
    ctx.stderr.flush() catch {};
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = &environ,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return spawnFail(bin, err);
    const term = child.wait(ctx.io) catch |err| return spawnFail(bin, err);
    ctx.exit_code = switch (term) {
        .exited => |code| code,
        // Как `os.Exit(-1)` в Go после сигнала: 255.
        else => 255,
    };
}

fn spawnFail(bin: []const u8, err: anyerror) Error {
    const S = struct {
        var kv: [2]errs.KV = undefined;
    };
    S.kv = .{
        .{ .key = "command", .value = bin },
        .{ .key = "detail", .value = @errorName(err) },
    };
    return errs.fail(.{
        .code = .e013,
        .summary = "cannot run command",
        .context = &S.kv,
    }, error.PermissionDenied);
}

/// Как `exec.LookPath`: имя с `/` берётся как есть, остальное ищется в PATH
/// окружения процесса.
fn lookup(ctx: *Ctx, name: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    const path_var = ctx.environ.get("PATH") orelse "";
    if (try plugin.lookPath(ctx.arena, ctx.io, path_var, name)) |found| return found;

    const S = struct {
        var kv: [1]errs.KV = undefined;
    };
    S.kv[0] = .{ .key = "command", .value = name };
    return errs.fail(.{
        .code = .e012,
        .summary = "command not found",
        .context = &S.kv,
    }, error.FileNotFound);
}

// ---- тесты -------------------------------------------------------------------
//
// Потоки ребёнка наследуются, поэтому проверять через harness нечего:
// вывод ушёл бы в stdout тестов. Запускаем настоящий бинарь envee.

const testing = std.testing;
const harness = @import("test_harness.zig");

/// Каталог вне дерева репозитория: настоящий бинарь не знает про stop_at и
/// поднялся бы до конфигов самого проекта.
fn outsideTempDir(a: Allocator) !harness.TempDir {
    var random_bytes: [12]u8 = undefined;
    testing.io.random(&random_bytes);
    var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
    const path = try std.fs.path.join(a, &.{ "/tmp", try std.fmt.allocPrint(a, "envee-exec-{s}", .{&name}) });
    try std.Io.Dir.cwd().createDirPath(testing.io, path);
    return .{ .path = path };
}

fn runEnvee(a: Allocator, tmp: harness.TempDir, argv: []const []const u8) !std.process.RunResult {
    // Путь из build.zig относительный (от корня сборки), а ребёнок
    // запускается с другим cwd — делаем абсолютным.
    const rel = @import("test_options").envee_bin;
    const bin = if (std.fs.path.isAbsolute(rel)) rel else try std.fs.path.join(a, &.{ try std.process.currentPathAlloc(testing.io, a), rel });
    var full: std.ArrayList([]const u8) = .empty;
    try full.append(a, bin);
    try full.appendSlice(a, argv);

    var environ: std.process.Environ.Map = .init(a);
    try environ.put("HOME", tmp.path);
    try environ.put("XDG_DATA_HOME", try tmp.join(a, "xdg"));
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("OUTER", "kept");
    return std.process.run(a, testing.io, .{
        .argv = full.items,
        .cwd = .{ .path = tmp.path },
        .environ_map = &environ,
    });
}

test "exec runs the command with the resolved env and passes its exit code through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try outsideTempDir(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nGREETING = \"hi {{env.OUTER}}\"\n");

    // Не одобрено — E001, команда не запускается.
    const untrusted = try runEnvee(a, tmp, &.{ "exec", "--", "sh", "-c", "echo $GREETING" });
    try testing.expect(untrusted.term.exited != 0);
    try testing.expect(std.mem.indexOf(u8, untrusted.stderr, "[E001]") != null);

    _ = try runEnvee(a, tmp, &.{ "trust", "--yes" });
    const ok = try runEnvee(a, tmp, &.{ "exec", "--", "sh", "-c", "echo $GREETING; echo $OUTER" });
    try testing.expectEqual(@as(u8, 0), ok.term.exited);
    try testing.expectEqualStrings("hi kept\nkept\n", ok.stdout);

    // Код выхода ребёнка — код выхода envee.
    const failing = try runEnvee(a, tmp, &.{ "exec", "--", "sh", "-c", "exit 7" });
    try testing.expectEqual(@as(u8, 7), failing.term.exited);

    // Без команды — E003 с подсказкой; неизвестная команда — E012.
    const missing = try runEnvee(a, tmp, &.{"exec"});
    try testing.expect(std.mem.indexOf(u8, missing.stderr, "[E003]: missing command") != null);
    try testing.expect(std.mem.indexOf(u8, missing.stderr, "envee exec -- <command>") != null);
    const unknown = try runEnvee(a, tmp, &.{ "exec", "--", "definitely-not-a-command-xyz" });
    try testing.expect(std.mem.indexOf(u8, unknown.stderr, "[E012]: command not found") != null);
}
