const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    try out.print("envee-zig: {d} args\n", .{args.len});
    for (args, 0..) |arg, i| {
        try out.print("  [{d}] {s}\n", .{ i, arg });
    }
}

test "smoke" {
    try std.testing.expect(1 + 1 == 2);
}

// Заставляет компилятор включить тесты из всех модулей.
// По мере появления новых файлов — добавлять сюда.
test {
    _ = @import("env.zig");
    _ = @import("shell/escape.zig");
}
