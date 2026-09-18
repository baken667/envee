const std = @import("std");
const builtin = @import("builtin");

/// Цели релиза. Тот же набор, что у goreleaser в Go-версии: linux и macOS
/// на обеих архитектурах, windows только amd64. musl — статическая
/// линковка, бинарь работает на любом дистрибутиве.
const release_targets = [_][]const u8{
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-windows",
};

/// Плагины, которые поставляются вместе с envee: `envee-plugin-<name>` из
/// `src/envee_plugin_<name>.zig`.
const plugin_names = [_][]const u8{ "env", "infisical", "op", "sops" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Метаданные сборки. В Go их вписывали через -ldflags -X; здесь это
    // обычный модуль, который генерирует сама система сборки.
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option(
        []const u8,
        "version",
        "version string reported by `envee version`",
    ) orelse "0.0.0-dev");
    options.addOption([]const u8, "commit", b.option(
        []const u8,
        "commit",
        "git commit the binary was built from",
    ) orelse "unknown");
    options.addOption([]const u8, "date", b.option(
        []const u8,
        "date",
        "RFC3339 build timestamp",
    ) orelse "unknown");
    options.addOption([]const u8, "zig_version", builtin.zig_version_string);

    // Бинари для хоста: `zig build` кладёт их в zig-out/bin.
    const host = addBinaries(b, target, optimize, options, null);
    b.installArtifact(host.envee);
    for (host.plugins) |p| b.installArtifact(p);

    const run_cmd = b.addRunArtifact(host.envee);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Build and run envee").dependOn(&run_cmd.step);

    // Поддельный плагин для тестов plugin.zig. Отдельный модуль для тестов
    // нужен, чтобы путь к нему не попадал в боевой бинарь и чтобы `zig build`
    // не собирал его без надобности.
    const fake_plugin = b.addExecutable(.{
        .name = "envee-plugin-fake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/fakeplugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_options = b.addOptions();
    test_options.addOptionPath("fake_plugin", fake_plugin.getEmittedBin());
    for (plugin_names, host.plugins) |name, p| {
        test_options.addOptionPath(b.fmt("{s}_plugin", .{name}), p.getEmittedBin());
    }
    test_options.addOptionPath("envee_bin", host.envee.getEmittedBin());

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.addOptions("build_options", options);
    test_root.addOptions("test_options", test_options);

    const tests = b.addTest(.{ .root_module = test_root });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // `zig build release`: все цели сразу, ReleaseSafe и без отладочных
    // символов, в zig-out/release/<target>/. ReleaseSafe, а не ReleaseFast:
    // проверки на переполнение и выход за границы стоят немного, а envee
    // читает чужие файлы и говорит с чужими процессами.
    const release = b.step("release", "Cross-compile release binaries for every supported target");
    for (release_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const resolved = b.resolveTargetQuery(query);
        const bins = addBinaries(b, resolved, .ReleaseSafe, options, true);
        const dir: std.Build.InstallDir = .{ .custom = b.fmt("release/{s}", .{triple}) };
        for ([_]*std.Build.Step.Compile{bins.envee} ++ bins.plugins) |artifact| {
            const install = b.addInstallArtifact(artifact, .{
                .dest_dir = .{ .override = dir },
                // Отладочная база Windows в релиз не идёт.
                .pdb_dir = .disabled,
            });
            release.dependOn(&install.step);
        }
    }
}

const Binaries = struct {
    envee: *std.Build.Step.Compile,
    plugins: [plugin_names.len]*std.Build.Step.Compile,
};

/// Все бинари для одной цели. Плагины собираются вместе с ядром и
/// поставляются в том же архиве, одной версией.
fn addBinaries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    strip: ?bool,
) Binaries {
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    root.addOptions("build_options", options);
    var bins: Binaries = .{ .envee = b.addExecutable(.{ .name = "envee", .root_module = root }), .plugins = undefined };

    for (plugin_names, &bins.plugins) |name, *p| {
        const plugin_root = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/envee_plugin_{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        });
        plugin_root.addOptions("build_options", options);
        p.* = b.addExecutable(.{ .name = b.fmt("envee-plugin-{s}", .{name}), .root_module = plugin_root });
    }
    return bins;
}
