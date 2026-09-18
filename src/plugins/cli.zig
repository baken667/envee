//! Общее для плагинов, которые отдают работу чужой CLI (`infisical`, `op`,
//! `sops`): разбор подкоманды, поиск и запуск CLI с тайм-аутом и перевод её
//! отказа в ошибку протокола с её же текстом.
//!
//! Такие плагины сознательно не говорят с API сами: вход, ключи, выбор
//! аккаунта и инстанса уже умеет официальная CLI, и повторять это здесь
//! значило бы разойтись с ней при первом же изменении.
//!
//! Владение: всё из арены вызывающего.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const build_options = @import("build_options");
const protocol = @import("protocol.zig");
const core_plugin = @import("../plugin.zig");

pub const Input = protocol.Input;
pub const Request = protocol.Request;

pub const Code = struct { name: []const u8, recoverable: bool };

pub const Tool = struct {
    /// Имя плагина и источник в ответе (`source = "op"`).
    name: []const u8,
    /// Исполняемый файл CLI.
    cli: []const u8,
    /// Что сказать, когда CLI нет в PATH.
    install_hint: []const u8,
    /// Переменная, которой можно поменять тайм-аут (в миллисекундах).
    timeout_env: []const u8,
    /// Код ошибки по первой строке stderr CLI.
    classify: *const fn ([]const u8) Code,
};

/// Ядро убивает плагин через 10 с; CLI получает меньше, чтобы ответ с
/// объяснением успел дойти.
pub const default_timeout_ms: i64 = 8_000;

/// `metadata` | `version` | `resolve` — одинаково для всех плагинов.
pub fn dispatch(
    arena: Allocator,
    io: Io,
    in: Input,
    out: *Writer,
    err_out: *Writer,
    comptime name: []const u8,
    writeMetadata: *const fn (*Writer) Writer.Error!void,
    resolve: *const fn (Allocator, Io, Input, *Writer) Allocator.Error!u8,
) Allocator.Error!u8 {
    if (in.argv.len < 2) {
        err_out.writeAll("usage: envee-plugin-" ++ name ++ " <metadata|resolve|version>\n") catch {};
        return 2;
    }
    const sub = in.argv[1];
    if (std.mem.eql(u8, sub, "metadata")) {
        writeMetadata(out) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "version")) {
        out.print("envee-plugin-" ++ name ++ " version {s}\n", .{build_options.version}) catch {};
        return 0;
    }
    if (std.mem.eql(u8, sub, "resolve")) return resolve(arena, io, in, out);
    err_out.print("unknown subcommand: {s}\n", .{sub}) catch {};
    return 2;
}

/// Запускает `tool.cli` с `args` в `cwd` (пусто — каталог плагина) и
/// возвращает stdout. `null` — CLI не отработала, и ошибка протокола уже
/// записана в `out`.
pub fn exec(
    arena: Allocator,
    io: Io,
    in: Input,
    req: Request,
    out: *Writer,
    tool: Tool,
    args: []const []const u8,
    cwd: []const u8,
    extra_env: []const [2][]const u8,
) Allocator.Error!?[]const u8 {
    // CLI ищется по PATH из окружения запроса, а не процесса: spawn
    // разрешает argv[0] по окружению родителя, и подменить его (в тестах
    // или через `env PATH=...`) иначе нельзя.
    const cli_path = (try core_plugin.lookPath(arena, io, in.environ.get("PATH") orelse "", tool.cli)) orelse {
        try protocol.writeError(arena, out, req.request_id, "not_installed", tool.install_hint, false);
        return null;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, cli_path);
    try argv.appendSlice(arena, args);

    var environ = try in.environ.clone(arena);
    try environ.put("NO_COLOR", "1");
    for (extra_env) |kv| try environ.put(kv[0], kv[1]);

    const timeout_ms: i64 = blk: {
        const raw = in.environ.get(tool.timeout_env) orelse break :blk default_timeout_ms;
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
            try protocol.writeError(arena, out, req.request_id, "not_installed", tool.install_hint, false);
            return null;
        },
        error.Timeout => {
            try protocol.writeError(arena, out, req.request_id, "timeout", try std.fmt.allocPrint(arena, "{s} did not answer within {d} ms", .{ tool.cli, timeout_ms }), true);
            return null;
        },
        else => {
            try protocol.writeError(arena, out, req.request_id, "internal", try std.fmt.allocPrint(arena, "cannot run {s}: {s}", .{ tool.cli, @errorName(err) }), true);
            return null;
        },
    };

    if (result.term != .exited or result.term.exited != 0) {
        const detail = firstLine(result.stderr);
        const code = tool.classify(detail);
        const message = if (detail.len > 0)
            try std.fmt.allocPrint(arena, "{s}: {s}", .{ tool.cli, detail })
        else
            try std.fmt.allocPrint(arena, "{s} exited with {s}", .{ tool.cli, termName(arena, result.term) });
        try protocol.writeError(arena, out, req.request_id, code.name, message, code.recoverable);
        return null;
    }
    return result.stdout;
}

/// Сравнение без учёта регистра по первым 512 байтам: формулировки CLI не
/// документированы и меняются, так что классификация — по ключевым словам,
/// а сам текст всегда уходит пользователю целиком.
pub fn mentions(detail: []const u8, needles: []const []const u8) bool {
    var lower_buf: [512]u8 = undefined;
    const n = @min(detail.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..n], detail[0..n]);
    for (needles) |needle| if (std.mem.indexOf(u8, lower, needle) != null) return true;
    return false;
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

// ---- тестовая обвязка ----------------------------------------------------------
//
// Настоящие CLI в тестах не участвуют: поддельная — shell-скрипт во
// временном каталоге, который записывает свои аргументы в FAKE_CLI_ARGS и
// ведёт себя по FAKE_CLI_MODE. Так проверяется ровно то, за что отвечает
// плагин: какую команду он собирает и как переводит ответы.

const testing = std.testing;
const harness = @import("../cli/test_harness.zig");
const perms = @import("../perms.zig");

pub const Fixture = struct {
    tmp: harness.TempDir,
    environ: std.process.Environ.Map,
    args_file: []const u8,

    /// `script` — тело поддельной CLI с именем `cli`.
    pub fn create(a: Allocator, cli: []const u8, script: []const u8, mode: []const u8) !Fixture {
        // Поддельная CLI — shell-скрипт, а Windows его не запустит. Разбор
        // ссылок и метаданные проверяются там без неё.
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
        const tmp = try harness.TempDir.create(a);
        const bin_dir = try tmp.join(a, "bin");
        try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ bin_dir, cli }), .data = script, .flags = .{ .permissions = perms.fromMode(0o755) } });
        const args_file = try tmp.join(a, "args.txt");
        var environ: std.process.Environ.Map = .init(a);
        try environ.put("PATH", try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{bin_dir}));
        try environ.put("HOME", tmp.path);
        try environ.put("FAKE_CLI_ARGS", args_file);
        if (mode.len > 0) try environ.put("FAKE_CLI_MODE", mode);
        return .{ .tmp = tmp, .environ = environ, .args_file = args_file };
    }

    pub fn destroy(f: Fixture) void {
        f.tmp.destroy();
    }

    pub fn resolveWith(
        f: *const Fixture,
        a: Allocator,
        runFn: *const fn (Allocator, Io, Input, *Writer, *Writer) Allocator.Error!u8,
        ref: []const u8,
        profile: []const u8,
    ) !Run {
        var body: Writer.Allocating = .init(a);
        try body.writer.writeAll("{\"api_version\":1,\"request_id\":\"req-1\",\"spec\":{\"ref\":");
        try std.json.Stringify.value(ref, .{}, &body.writer);
        try body.writer.print("}},\"context\":{{\"config_root\":\"{s}\",\"cwd\":\"{s}\",\"profile\":\"{s}\",\"env\":{{}}}}}}", .{ f.tmp.path, f.tmp.path, profile });
        var out: Writer.Allocating = .init(a);
        var err_out: Writer.Allocating = .init(a);
        const code = try runFn(a, testing.io, .{ .argv = &.{ "p", "resolve" }, .stdin = body.written(), .environ = &f.environ, .now_ns = 0 }, &out.writer, &err_out.writer);
        return .{ .code = code, .stdout = out.written() };
    }

    pub fn recordedArgs(f: *const Fixture, a: Allocator) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, f.args_file, a, .unlimited);
    }

    /// Кладёт собранный плагин рядом с поддельной CLI, чтобы ядро нашло его.
    pub fn installPlugin(f: *const Fixture, a: Allocator, name: []const u8, built: []const u8) !void {
        const bin = try Io.Dir.cwd().readFileAlloc(testing.io, built, a, .unlimited);
        const dst = try f.tmp.join(a, try std.fs.path.join(a, &.{ "bin", try core_plugin.testExeName(a, name) }));
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dst, .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });
    }
};

pub const Run = struct { code: u8, stdout: []const u8 };

pub fn response(a: Allocator, stdout: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, stdout, .{});
    try testing.expect(v == .object);
    return v.object;
}

pub fn errorCode(o: std.json.ObjectMap) []const u8 {
    return protocol.stringField(o.get("error").?.object, "code").?;
}

pub fn errorMessage(o: std.json.ObjectMap) []const u8 {
    return protocol.stringField(o.get("error").?.object, "message").?;
}

pub fn okValue(o: std.json.ObjectMap) []const u8 {
    return protocol.stringField(o.get("value").?.object, "value").?;
}
