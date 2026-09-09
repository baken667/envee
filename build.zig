const std = @import("std");
const builtin = @import("builtin");

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

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "envee",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
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
}
