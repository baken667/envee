//! Поведенческие тесты сгенерированных hook'ов на живых оболочках.
//!
//! Порт `internal/shell/fastpath_test.go`. Здесь проверяется не текст, а
//! поведение: fast path — это утверждение о том, что envee НЕ запускается,
//! и подтвердить его может только счётчик запусков.
//!
//! Вместо настоящего бинаря подставляется скрипт, который дописывает строку
//! в файл-счётчик и печатает заранее заданный вывод `eval`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shell = @import("shell.zig");
const escape = @import("escape.zig");

const testing = std.testing;
const io = std.testing.io;

/// Временный каталог с известным абсолютным путём: путь придётся
/// подставлять в текст shell-скриптов, а `Io.Dir` его не сообщает.
const TempDir = struct {
    path: []const u8,

    fn create(gpa: Allocator) !TempDir {
        const cwd_path = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd_path);

        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);

        const path = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &name });
        errdefer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path };
    }

    fn destroy(t: TempDir, gpa: Allocator) void {
        std.Io.Dir.cwd().deleteTree(io, t.path) catch {};
        gpa.free(t.path);
    }

    fn join(t: TempDir, gpa: Allocator, sub: []const u8) ![]const u8 {
        return std.fs.path.join(gpa, &.{ t.path, sub });
    }
};

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeExecutable(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .permissions = .executable_file },
    });
}

/// Подставляет путь в текст shell-скрипта. Временные каталоги смирные, но
/// собирать скрипты конкатенацией — ровно та привычка, из которой выросли
/// уже случавшиеся в этом проекте дыры в экранировании.
fn shq(gpa: Allocator, s: []const u8) ![]const u8 {
    return escape.singleQuote(gpa, s);
}

/// Скрипт-подстава вместо бинаря envee: считает запуски и печатает вывод eval.
fn countingEnvee(gpa: Allocator, dir: TempDir, counter: []const u8, eval_output: []const u8) ![]const u8 {
    const path = try dir.join(gpa, "envee");
    const script = try std.fmt.allocPrint(
        gpa,
        "#!/bin/sh\necho x >> {s}\ncat <<'ENVEE_EOF'\n{s}ENVEE_EOF\n",
        .{ counter, eval_output },
    );
    try writeExecutable(path, script);
    return path;
}

/// Подстава, которая считает запуски и падает — как при недоверенном конфиге.
fn failingEnvee(gpa: Allocator, dir: TempDir, counter: []const u8) ![]const u8 {
    const path = try dir.join(gpa, "envee");
    const script = try std.fmt.allocPrint(gpa, "#!/bin/sh\necho x >> {s}\nexit 3\n", .{counter});
    try writeExecutable(path, script);
    return path;
}

fn readCount(gpa: Allocator, counter: []const u8) !usize {
    const data = std.Io.Dir.cwd().readFileAlloc(io, counter, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer gpa.free(data);
    return std.mem.count(u8, data, "\n");
}

/// Запускает скрипт в оболочке. null — оболочки нет на машине.
fn runScript(gpa: Allocator, shell_bin: []const u8, script: []const u8) !?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ shell_bin, "-c", script },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(result.stderr);
    return result.stdout;
}

const HookCase = struct {
    /// Имя оболочки и одновременно имя её бинаря.
    shell: []const u8,
    adapter: shell.Adapter,
    /// Как вызвать hook вручную, изображая новое приглашение.
    entry: []const u8,
    /// Строка, которую печатает подстава как результат eval.
    export_line: []const u8,
};

const hook_cases = [_]HookCase{
    .{ .shell = "bash", .adapter = .bash, .entry = "_envee_hook", .export_line = "export MARK=one;\n" },
    .{ .shell = "zsh", .adapter = .zsh, .entry = "_envee_chpwd", .export_line = "export MARK=one;\n" },
    .{ .shell = "fish", .adapter = .fish, .entry = "_envee_hook", .export_line = "set -gx MARK one\n" },
};

/// Собирает вывод eval: строка экспорта плюс список зависимостей fast path.
fn evalOutput(gpa: Allocator, c: HookCase, deps: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    try aw.writer.writeAll(c.export_line);
    try c.adapter.writeFastPath(&aw.writer, deps);
    return aw.toOwnedSlice();
}

fn writeHook(gpa: Allocator, dir: TempDir, c: HookCase, bin: []const u8) ![]const u8 {
    const path = try dir.join(gpa, "hook");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try c.adapter.writeInit(&aw.writer, bin);
    try writeFile(path, aw.written());
    return path;
}

// Ради чего всё затевалось: если ничего не изменилось, повторные
// приглашения не должны запускать envee ни разу больше.
test "fast path: repeated prompts do not run envee again" {
    for (hook_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = try TempDir.create(a);
        defer dir.destroy(a);

        const counter = try dir.join(a, "calls");
        const watched = try dir.join(a, "envee.toml");
        try writeFile(watched, "x");

        const bin = try countingEnvee(a, dir, counter, try evalOutput(a, c, &.{watched}));
        const hook = try writeHook(a, dir, c, bin);

        // Один первый вызов, затем девять приглашений без изменений.
        var script: std.Io.Writer.Allocating = .init(a);
        try script.writer.print("cd {s}\nsource {s}\n", .{ try shq(a, dir.path), try shq(a, hook) });
        for (0..10) |_| try script.writer.print("{s}\n", .{c.entry});

        if (try runScript(a, c.shell, script.written()) == null) return error.SkipZigTest;

        const got = try readCount(a, counter);
        testing.expectEqual(@as(usize, 1), got) catch |err| {
            std.debug.print("{s}: envee ran {d} times across 10 prompts, fast path should allow 1\n", .{ c.shell, got });
            return err;
        };
    }
}

test "fast path: a changed dependency breaks it" {
    for (hook_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = try TempDir.create(a);
        defer dir.destroy(a);

        const counter = try dir.join(a, "calls");
        const watched = try dir.join(a, "envee.toml");
        try writeFile(watched, "x");

        const bin = try countingEnvee(a, dir, counter, try evalOutput(a, c, &.{watched}));
        const hook = try writeHook(a, dir, c, bin);

        // Приглашение, трогаем зависимость, снова приглашение. sleep даёт
        // файловой системе различимое время модификации.
        const script = try std.fmt.allocPrint(
            a,
            "cd {s}\nsource {s}\n{s}\n{s}\nsleep 1.1\ntouch {s}\n{s}\n",
            .{ try shq(a, dir.path), try shq(a, hook), c.entry, c.entry, try shq(a, watched), c.entry },
        );
        if (try runScript(a, c.shell, script) == null) return error.SkipZigTest;

        const got = try readCount(a, counter);
        testing.expectEqual(@as(usize, 2), got) catch |err| {
            std.debug.print("{s}: envee ran {d} times, expected 2\n", .{ c.shell, got });
            return err;
        };
    }
}

test "fast path: changing directory breaks it even with no file change" {
    for (hook_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = try TempDir.create(a);
        defer dir.destroy(a);

        const other = try dir.join(a, "sub");
        try std.Io.Dir.cwd().createDirPath(io, other);

        const counter = try dir.join(a, "calls");
        const watched = try dir.join(a, "envee.toml");
        try writeFile(watched, "x");

        const bin = try countingEnvee(a, dir, counter, try evalOutput(a, c, &.{watched}));
        const hook = try writeHook(a, dir, c, bin);

        const script = try std.fmt.allocPrint(
            a,
            "cd {s}\nsource {s}\n{s}\ncd {s}\n{s}\n",
            .{ try shq(a, dir.path), try shq(a, hook), c.entry, try shq(a, other), c.entry },
        );
        if (try runScript(a, c.shell, script) == null) return error.SkipZigTest;

        const got = try readCount(a, counter);
        testing.expectEqual(@as(usize, 2), got) catch |err| {
            std.debug.print("{s}: envee ran {d} times after cd, expected 2\n", .{ c.shell, got });
            return err;
        };
    }
}

// Упавший envee НЕ должен взводить fast path, иначе `envee trust` внешне
// ничего не делает до следующей смены каталога.
test "fast path: a failing run keeps retrying" {
    for (hook_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = try TempDir.create(a);
        defer dir.destroy(a);

        const counter = try dir.join(a, "calls");
        const bin = try failingEnvee(a, dir, counter);
        const hook = try writeHook(a, dir, c, bin);

        var script: std.Io.Writer.Allocating = .init(a);
        try script.writer.print("cd {s}\nsource {s}\n", .{ try shq(a, dir.path), try shq(a, hook) });
        for (0..3) |_| try script.writer.print("{s}\n", .{c.entry});

        if (try runScript(a, c.shell, script.written()) == null) return error.SkipZigTest;

        const got = try readCount(a, counter);
        testing.expectEqual(@as(usize, 3), got) catch |err| {
            std.debug.print("{s}: envee ran {d} times, a failing run must retry every prompt\n", .{ c.shell, got });
            return err;
        };
    }
}

// Список зависимостей исполняется оболочкой как код, ровно как значения
// переменных. Пробелы и кавычки в путях обязаны его пережить.
test "fast path: awkward paths survive the dependency list" {
    for (hook_cases) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const dir = try TempDir.create(a);
        defer dir.destroy(a);

        const awkward = try dir.join(a, "a dir with spaces");
        try std.Io.Dir.cwd().createDirPath(io, awkward);
        const dep = try std.fs.path.join(a, &.{ awkward, "it's here.toml" });
        try writeFile(dep, "x");

        const counter = try dir.join(a, "calls");
        const bin = try countingEnvee(a, dir, counter, try evalOutput(a, c, &.{dep}));
        const hook = try writeHook(a, dir, c, bin);

        var script: std.Io.Writer.Allocating = .init(a);
        try script.writer.print("cd {s}\nsource {s}\n", .{ try shq(a, dir.path), try shq(a, hook) });
        for (0..4) |_| try script.writer.print("{s}\n", .{c.entry});

        const out = (try runScript(a, c.shell, script.written())) orelse return error.SkipZigTest;

        const got = try readCount(a, counter);
        testing.expectEqual(@as(usize, 1), got) catch |err| {
            std.debug.print("{s}: envee ran {d} times, the awkward path likely broke the list\noutput: {s}\n", .{ c.shell, got, out });
            return err;
        };
    }
}

// Hook работает из приглашения, поэтому обязан не трогать код возврата
// вызывающего: приглашение, показывающее $?, не должно вместо команды
// пользователя сообщать о внутренностях envee.
test "hook preserves the caller's exit status" {
    const Probe = struct {
        /// (exit N) — подоболочка в POSIX, но подстановка команды в fish,
        /// где такого синтаксиса нет; отсюда разное написание.
        set_status: []const u8,
        probe: []const u8,
    };
    const probes = [_]Probe{
        .{ .set_status = "(exit 42)", .probe = "echo \"status=$?\"" },
        .{ .set_status = "(exit 42)", .probe = "echo \"status=$?\"" },
        .{ .set_status = "sh -c 'exit 42'", .probe = "echo \"status=$status\"" },
    };

    for (hook_cases, probes) |c, p| {
        for ([_]bool{ true, false }) |succeeding| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const dir = try TempDir.create(a);
            defer dir.destroy(a);

            const counter = try dir.join(a, "calls");
            const dep = try dir.join(a, "envee.toml");
            try writeFile(dep, "x");

            const bin = if (succeeding)
                try countingEnvee(a, dir, counter, try evalOutput(a, c, &.{dep}))
            else
                try failingEnvee(a, dir, counter);
            const hook = try writeHook(a, dir, c, bin);

            const script = try std.fmt.allocPrint(
                a,
                "cd {s}\nsource {s}\n{s}\n{s}\n{s}\n",
                .{ try shq(a, dir.path), try shq(a, hook), p.set_status, c.entry, p.probe },
            );
            const out = (try runScript(a, c.shell, script)) orelse return error.SkipZigTest;

            if (std.mem.indexOf(u8, out, "status=42") == null) {
                std.debug.print("{s} ({s}): hook clobbered the exit status, got: {s}\n", .{
                    c.shell,
                    if (succeeding) "succeeding" else "failing",
                    std.mem.trim(u8, out, " \n"),
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}
