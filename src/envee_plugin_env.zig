//! Точка входа `envee-plugin-env`. Вся логика — в `plugins/env.zig`; здесь
//! только процесс: argv, stdin, окружение, потоки и код выхода.
//!
//! Файл лежит в корне `src/`, а не в `src/plugins/`: корень модуля задаёт
//! каталог, за пределы которого `@import` не выходит, а плагину нужны
//! `secret_store.zig` и `trust/store.zig`.

const std = @import("std");
const Io = std.Io;
const env_plugin = @import("plugins/env.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &err_buf);

    // stdin читается только для resolve, но читать его заранее безопасно:
    // для остальных подкоманд ядро ничего не шлёт, а поток закрыт.
    var stdin: []const u8 = "";
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "resolve")) {
        var in_buf: [4096]u8 = undefined;
        var stdin_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
        stdin = try stdin_file.interface.allocRemaining(arena, .unlimited);
    }

    const code = try env_plugin.run(arena, io, .{
        .argv = argv,
        .stdin = stdin,
        .environ = init.environ_map,
        .now_ns = Io.Timestamp.now(io, .real).nanoseconds,
    }, &stdout_file.interface, &stderr_file.interface);

    stdout_file.interface.flush() catch {};
    stderr_file.interface.flush() catch {};
    std.process.exit(code);
}
