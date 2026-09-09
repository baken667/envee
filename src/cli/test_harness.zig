//! Обвязка для тестов команд.
//!
//! Отдельный файл, потому что ей пользуются тесты нескольких команд сразу.
//! Рабочий каталог процесса менять нельзя (тесты идут параллельно), поэтому
//! каталог подставляется полем `Ctx.cwd`, а не сменой cwd.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const env_mod = @import("../env.zig");
const paths_mod = @import("../paths.zig");
const root = @import("root.zig");
const trust_cmd = @import("trust.zig");
const trust_store = @import("../trust/store.zig");

const io = std.testing.io;

pub const TempDir = struct {
    path: []const u8,

    pub fn create(gpa: Allocator) !TempDir {
        const cwd_path = try std.process.currentPathAlloc(io, gpa);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const path = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path };
    }

    pub fn destroy(t: TempDir) void {
        std.Io.Dir.cwd().deleteTree(io, t.path) catch {};
    }

    /// Записывает `envee.toml` в корень каталога.
    pub fn write(t: TempDir, gpa: Allocator, body: []const u8) !void {
        try t.writeFile(gpa, "envee.toml", body);
    }

    pub fn writeFile(t: TempDir, gpa: Allocator, sub: []const u8, body: []const u8) !void {
        const full = try std.fs.path.join(gpa, &.{ t.path, sub });
        if (std.fs.path.dirname(full)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = body });
    }

    pub fn join(t: TempDir, gpa: Allocator, sub: []const u8) ![]const u8 {
        return std.fs.path.join(gpa, &.{ t.path, sub });
    }
};

pub const Output = struct {
    stdout: []const u8,
    stderr: []const u8,
};

/// Выполняет команду с разрешающим гейтом доверия и возвращает stdout.
pub fn run(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
) ![]const u8 {
    return (try runFull(gpa, dir, argv, os_pairs, context.TrustGate.allowAll())).stdout;
}

/// То же, но с гейтом по умолчанию — то есть ничего не одобрено.
pub fn runUntrusted(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
) ![]const u8 {
    return (try runFull(gpa, dir, argv, os_pairs, context.TrustGate.denyAll())).stdout;
}

/// Выполняет команду с НАСТОЯЩИМ хранилищем доверия в каталоге теста.
///
/// Именно этим проверяется связка «одобрить → применить»: с подставным
/// гейтом она была бы проверкой заглушки.
pub fn runReal(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
    asker: ?trust_cmd.Asker,
) ![]const u8 {
    return (try runRealFull(gpa, dir, argv, os_pairs, asker)).stdout;
}

pub fn runRealFull(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
    asker: ?trust_cmd.Asker,
) !Output {
    var environ: std.process.Environ.Map = .init(gpa);
    try environ.put("HOME", dir.path);
    try environ.put("USER", "tester");
    // Хранилище — внутри каталога теста: тесты идут параллельно и не должны
    // делить состояние ни между собой, ни с настоящим хранилищем машины.
    try environ.put("XDG_DATA_HOME", try std.fs.path.join(gpa, &.{ dir.path, "xdg-data" }));
    for (os_pairs) |p| try environ.put(p[0], p[1]);

    var os_env: env_mod.Map = .empty;
    for (os_pairs) |p| try os_env.set(gpa, p[0], p[1]);

    var out: Writer.Allocating = .init(gpa);
    var err_out: Writer.Allocating = .init(gpa);
    const paths = try paths_mod.Paths.init(gpa, &environ);

    var gate: trust_cmd.Gate = .{
        .arena = gpa,
        .store = .{
            .root = paths.trust_store,
            .io = io,
            .now_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
            .user = "tester",
            .tool_version = "0.4.0-test",
        },
    };

    var ctx: context.Ctx = .{
        .arena = gpa,
        .io = io,
        .environ = &environ,
        .os_env = os_env,
        .paths = paths,
        .cwd = dir.path,
        .stdout = &out.writer,
        .stderr = &err_out.writer,
        .self_path = "/usr/local/bin/envee",
        .tool_version = "0.4.0-test",
        .trust = gate.trustGate(),
    };

    const parsed = try args_mod.parse(gpa, &root.root, argv, null);
    try root.runWith(&ctx, parsed, dir.path, asker);
    return .{ .stdout = out.written(), .stderr = err_out.written() };
}

pub fn runFull(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
    gate: context.TrustGate,
) !Output {
    var environ: std.process.Environ.Map = .init(gpa);
    try environ.put("HOME", dir.path);
    for (os_pairs) |p| try environ.put(p[0], p[1]);

    var os_env: env_mod.Map = .empty;
    for (os_pairs) |p| try os_env.set(gpa, p[0], p[1]);

    var out: Writer.Allocating = .init(gpa);
    var err_out: Writer.Allocating = .init(gpa);

    var ctx: context.Ctx = .{
        .arena = gpa,
        .io = io,
        .environ = &environ,
        .os_env = os_env,
        .paths = try paths_mod.Paths.init(gpa, &environ),
        .cwd = dir.path,
        .stdout = &out.writer,
        .stderr = &err_out.writer,
        .self_path = "/usr/local/bin/envee",
        .tool_version = "0.4.0-test",
        .trust = gate,
    };

    const parsed = try args_mod.parse(gpa, &root.root, argv, null);
    // Подъём по дереву ограничен временным каталогом: иначе тест подхватил
    // бы конфиги самого репозитория.
    try root.runWithStopAt(&ctx, parsed, dir.path);
    return .{ .stdout = out.written(), .stderr = err_out.written() };
}
