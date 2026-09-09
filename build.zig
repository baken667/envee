const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "envee",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Build and run envee").dependOn(&run_cmd.step);

    // ВРЕМЕННО: бинарь только для scripts/parity.sh, пока настоящего CLI нет.
    // Удалить вместе с src/dev_main.zig на шаге 15 (см. docs/zig-rewrite-steps.md).
    const dev_exe = b.addExecutable(.{
        .name = "envee-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(dev_exe);

    const tests = b.addTest(.{ .root_module = root });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
