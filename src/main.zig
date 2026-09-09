//! Точка входа `envee`.
//!
//! Собирает контекст процесса, разбирает аргументы и передаёт управление
//! дереву команд. Здесь же единственное место, где ошибка превращается в код
//! возврата: на эти коды опираются shell-hook и пользовательские скрипты
//! (docs/adr/0017-error-ux.md).

const std = @import("std");
const Io = std.Io;

const args_mod = @import("cli/args.zig");
const cli = @import("cli/root.zig");
const cli_context = @import("cli/context.zig");
const trust_cmd = @import("cli/trust.zig");
const trust_store = @import("trust/store.zig");
const env_mod = @import("env.zig");
const errs = @import("errs.zig");
const paths_mod = @import("paths.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // Буфер stdout большой намеренно: вывод eval уходит целиком в подстановку
    // команд оболочки, и дробить его на записи незачем.
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_file.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const err_out = &stderr_file.interface;

    const code = dispatch(arena, io, init, out, err_out) catch |err| blk: {
        // У ошибки почти всегда есть подробная диагностика; если её нет,
        // печатаем хотя бы имя — молчаливый выход с ненулевым кодом ничего
        // не объясняет.
        if (errs.take()) |d| {
            // «Error: » перед диагностикой — форма, к которой приучила
            // cobra; на неё смотрят и глазами, и grep'ом.
            err_out.writeAll("Error: ") catch {};
            d.write(err_out) catch {};
            err_out.writeByte('\n') catch {};
            break :blk d.exitCode();
        }
        err_out.print("Error: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };

    out.flush() catch {};
    err_out.flush() catch {};
    std.process.exit(code);
}

fn dispatch(
    arena: std.mem.Allocator,
    io: Io,
    init: std.process.Init,
    out: *Io.Writer,
    err_out: *Io.Writer,
) !u8 {
    const argv = try init.minimal.args.toSlice(arena);
    const rest = if (argv.len > 0) argv[1..] else argv;

    var diag: args_mod.Diagnostics = .{};
    const parsed = args_mod.parse(arena, &cli.root, rest, &diag) catch |err| {
        args_mod.writeError(err_out, err, diag) catch {};
        // Неверный вызов — это код 2, как у cobra: скрипт должен отличать
        // «команда не так написана» от «команда отработала и не смогла».
        return 2;
    };

    if (parsed.help) {
        try args_mod.writeHelp(arena, out, parsed.path);
        return 0;
    }
    if (parsed.version) {
        try out.print("envee version {s}\n", .{try cli.versionString(arena)});
        return 0;
    }

    cli.configureLogging(parsed, err_out);

    var gate: trust_cmd.Gate = .{
        .arena = arena,
        .store = .{
            .root = (try paths_mod.Paths.init(arena, init.environ_map)).trust_store,
            .io = io,
            .now_ns = Io.Timestamp.now(io, .real).nanoseconds,
            .user = init.environ_map.get("USER") orelse (init.environ_map.get("USERNAME") orelse "unknown"),
            .tool_version = cli.build_options.version,
        },
    };

    var ctx: cli_context.Ctx = .{
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .os_env = try env_mod.Map.fromEnviron(arena, init.environ_map),
        .paths = try paths_mod.Paths.init(arena, init.environ_map),
        .stdout = out,
        .stderr = err_out,
        .cwd = try std.process.currentPathAlloc(io, arena),
        .self_path = try std.process.executablePathAlloc(io, arena),
        .tool_version = cli.build_options.version,
        .trust = gate.trustGate(),
    };

    // Вопрос задаётся только когда есть кому отвечать; иначе `envee trust`
    // честно откажется, а не одобрит молча.
    var stdin_asker: trust_cmd.StdinAsker = .{ .io = io, .out = err_out };
    try cli.runWith(&ctx, parsed, "", stdin_asker.asker());
    return 0;
}

// Заставляет компилятор включить тесты из всех модулей.
// По мере появления новых файлов — добавлять сюда.
test {
    _ = @import("env.zig");
    _ = @import("dotenv.zig");
    _ = @import("template.zig");
    _ = @import("path.zig");
    _ = @import("paths.zig");
    _ = @import("errs.zig");
    _ = @import("log.zig");
    _ = @import("shell/escape.zig");
    _ = @import("shell/shell.zig");
    _ = @import("shell/hook_test.zig");
    _ = @import("toml/lexer.zig");
    _ = @import("toml/value.zig");
    _ = @import("toml/parser.zig");
    _ = @import("config.zig");
    _ = @import("resolver.zig");
    _ = @import("directive.zig");
    _ = @import("directive/file.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/context.zig");
    _ = @import("cli/root.zig");
    _ = @import("cli/resolve.zig");
    _ = @import("cli/check.zig");
    _ = @import("trust/store.zig");
    _ = @import("trust/summary.zig");
    _ = @import("cli/trust.zig");
}
