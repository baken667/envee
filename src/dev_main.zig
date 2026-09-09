//! ВРЕМЕННЫЙ бинарь `envee-dev`, существующий только ради parity-проверок.
//!
//! Настоящий разбор аргументов появится на шаге 14, команда `init` — на
//! шаге 15. До тех пор parity нужен уже сейчас: сверять вывод с Go имеет
//! смысл с первого же портированного модуля, а не после того, как соберётся
//! весь CLI.
//!
//! Поддерживает ровно одну команду: `envee-dev init <shell>`.
//! Удалить вместе с целью `envee-dev` в build.zig на шаге 15.

const std = @import("std");
const Io = std.Io;

const shell = @import("shell/shell.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err_out = &stderr_file.interface;
    defer err_out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "init")) {
        try err_out.writeAll("usage: envee-dev init <shell>\n");
        try err_out.flush();
        std.process.exit(2);
    }

    const adapter = shell.Adapter.detect(args[2]) orelse {
        try err_out.print("unsupported shell {s}\n", .{args[2]});
        try err_out.flush();
        std.process.exit(2);
    };

    // Go-версия берёт путь через os.Executable(); повторяем, чтобы
    // сгенерированный hook ссылался на реальный бинарь.
    const self_path = try std.process.executablePathAlloc(io, arena);
    try adapter.writeInit(out, self_path);
}
