//! Разбор аргументов командной строки: дерево команд, флаги, справка.
//!
//! Заменяет `spf13/cobra` из Go-версии. Форма вывода справки и текст ошибок
//! повторяют cobra: к ним привыкли пользователи, на них ссылается README.
//!
//! Отличие от Go по ПОВЕДЕНИЮ: флаг `-v` там объявлен булевым
//! (`pf.BoolP("verbose", ...)`), а читается как число
//! (`cmd.Flags().GetInt("verbose")`). GetInt на булевом флаге возвращает
//! ошибку, которую отбрасывают, и значение остаётся нулём — то есть `-v` и
//! `-vv` не делают ничего. Здесь это настоящий счётчик.
//!
//! Владение: `Parsed` ссылается на срезы argv и на статическое описание
//! команд; собственных копий не делает, кроме списка значений флагов.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const FlagKind = union(enum) {
    /// Присутствие флага само по себе значимо.
    boolean,
    /// Флаг со значением; строка — значение по умолчанию.
    string: []const u8,
    /// Счётчик повторов: `-v`, `-vv`, `-vvv`.
    counter,
};

pub const Flag = struct {
    long: []const u8,
    /// Короткая форма или 0, если её нет.
    short: u8 = 0,
    kind: FlagKind = .boolean,
    help: []const u8 = "",
    /// Наследуется подкомандами. В справке подкоманды такие флаги
    /// показываются отдельным разделом «Global Flags», как в cobra.
    persistent: bool = false,
    /// В справке не показывается.
    hidden: bool = false,
};

/// Сколько позиционных аргументов принимает команда.
pub const ArgSpec = union(enum) {
    none,
    exact: usize,
    minimum: usize,
    any,
    /// Всё после `--` уходит команде как есть. Для `envee exec -- cmd args`.
    passthrough,
};

pub const Command = struct {
    name: []const u8,
    /// Хвост строки Usage: для `eval` это `<shell>`.
    usage_args: []const u8 = "",
    short: []const u8 = "",
    long: []const u8 = "",
    flags: []const Flag = &.{},
    args: ArgSpec = .none,
    subcommands: []const Command = &.{},
    /// Не показывается в списке команд. Так помечено то, что объявлено, но
    /// не реализовано: команда остаётся, честно падает, но не обещает.
    hidden: bool = false,

    fn findSub(c: *const Command, name: []const u8) ?*const Command {
        for (c.subcommands) |*sub| {
            if (std.mem.eql(u8, sub.name, name)) return sub;
        }
        return null;
    }
};

pub const Error = error{
    UnknownCommand,
    UnknownFlag,
    MissingFlagValue,
    /// Позиционных аргументов не столько, сколько нужно команде.
    WrongArgCount,
} || Allocator.Error;

pub const Diagnostics = struct {
    /// Что не опознали.
    token: []const u8 = "",
    /// Полное имя команды, в контексте которой случилась ошибка.
    command: []const u8 = "envee",
    /// Похожие команды — для «Did you mean this?».
    suggestions: []const []const u8 = &.{},
    /// Пояснение к WrongArgCount.
    detail: []const u8 = "",
};

const Value = union(enum) {
    boolean: bool,
    string: []const u8,
    counter: usize,
};

const Set = struct {
    long: []const u8,
    value: Value,
};

pub const Parsed = struct {
    /// Цепочка команд от корня: для `envee secret set` это три элемента.
    path: []const *const Command,
    /// Команда, которую в итоге выбрали.
    command: *const Command,
    /// Позиционные аргументы.
    args: []const []const u8,
    /// Запрошена справка (`--help` или `-h`).
    help: bool = false,
    /// Запрошена версия (`--version`).
    version: bool = false,

    values: []const Set,

    pub fn commandPath(p: Parsed, gpa: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (p.path, 0..) |c, i| {
            if (i > 0) try out.append(gpa, ' ');
            try out.appendSlice(gpa, c.name);
        }
        return out.toOwnedSlice(gpa);
    }

    fn raw(p: Parsed, long: []const u8) ?Value {
        for (p.values) |v| {
            if (std.mem.eql(u8, v.long, long)) return v.value;
        }
        return null;
    }

    /// Значение строкового флага; если он не задан — значение по умолчанию
    /// из описания команды.
    pub fn str(p: Parsed, long: []const u8) []const u8 {
        if (p.raw(long)) |v| {
            if (v == .string) return v.string;
        }
        for (p.path) |c| {
            for (c.flags) |f| {
                if (std.mem.eql(u8, f.long, long) and f.kind == .string) return f.kind.string;
            }
        }
        return "";
    }

    pub fn boolean(p: Parsed, long: []const u8) bool {
        if (p.raw(long)) |v| {
            if (v == .boolean) return v.boolean;
        }
        return false;
    }

    pub fn count(p: Parsed, long: []const u8) usize {
        if (p.raw(long)) |v| {
            if (v == .counter) return v.counter;
        }
        return 0;
    }
};

/// Разбирает argv (без имени программы).
pub fn parse(
    gpa: Allocator,
    root: *const Command,
    argv: []const []const u8,
    diag: ?*Diagnostics,
) Error!Parsed {
    var path: std.ArrayList(*const Command) = .empty;
    try path.append(gpa, root);
    var args: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Set) = .empty;

    var want_help = false;
    var want_version = false;
    var current = root;
    // После `--` всё уходит в аргументы без разбора.
    var literal = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (literal) {
            try args.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;

            if (std.mem.eql(u8, name, "help")) {
                want_help = true;
                continue;
            }
            if (std.mem.eql(u8, name, "version") and current == root) {
                want_version = true;
                continue;
            }

            const flag = lookupFlag(path.items, name) orelse {
                if (diag) |d| d.* = .{ .token = arg, .command = current.name };
                return error.UnknownFlag;
            };
            switch (flag.kind) {
                .boolean => try setValue(gpa, &values, name, .{ .boolean = true }),
                .counter => {
                    const prev = currentCount(values.items, name);
                    try setValue(gpa, &values, name, .{ .counter = prev + 1 });
                },
                .string => {
                    const text = if (eq) |e| body[e + 1 ..] else blk: {
                        i += 1;
                        if (i >= argv.len) {
                            if (diag) |d| d.* = .{ .token = arg, .command = current.name };
                            return error.MissingFlagValue;
                        }
                        break :blk argv[i];
                    };
                    try setValue(gpa, &values, name, .{ .string = text });
                },
            }
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            // Короткие флаги можно писать слитно: -vv, -qv. Значение
            // строкового флага, если оно есть, идёт следующим аргументом.
            for (arg[1..], 0..) |ch, pos| {
                if (ch == 'h') {
                    want_help = true;
                    continue;
                }
                const flag = lookupShort(path.items, ch) orelse {
                    if (diag) |d| d.* = .{ .token = arg, .command = current.name };
                    return error.UnknownFlag;
                };
                switch (flag.kind) {
                    .boolean => try setValue(gpa, &values, flag.long, .{ .boolean = true }),
                    .counter => {
                        const prev = currentCount(values.items, flag.long);
                        try setValue(gpa, &values, flag.long, .{ .counter = prev + 1 });
                    },
                    .string => {
                        // Остаток кластера — значение, иначе следующий аргумент.
                        const rest = arg[1 + pos + 1 ..];
                        const text = if (rest.len > 0) rest else blk: {
                            i += 1;
                            if (i >= argv.len) {
                                if (diag) |d| d.* = .{ .token = arg, .command = current.name };
                                return error.MissingFlagValue;
                            }
                            break :blk argv[i];
                        };
                        try setValue(gpa, &values, flag.long, .{ .string = text });
                        break;
                    },
                }
            }
            continue;
        }

        // Не флаг: подкоманда, если такая есть и позиционных ещё не было.
        if (args.items.len == 0) {
            if (current.findSub(arg)) |sub| {
                current = sub;
                try path.append(gpa, sub);
                continue;
            }
            // Команда с подкомандами и без собственных аргументов не может
            // принять произвольное слово — это опечатка, и лучше о ней
            // сказать, чем молча ничего не сделать.
            if (current.subcommands.len > 0 and current.args == .none) {
                if (diag) |d| d.* = .{
                    .token = arg,
                    .command = current.name,
                    .suggestions = try suggest(gpa, current, arg),
                };
                return error.UnknownCommand;
            }
        }
        try args.append(gpa, arg);
    }

    const parsed: Parsed = .{
        .path = try path.toOwnedSlice(gpa),
        .command = current,
        .args = try args.toOwnedSlice(gpa),
        .help = want_help,
        .version = want_version,
        .values = try values.toOwnedSlice(gpa),
    };

    // Справка и версия важнее числа аргументов: `envee eval --help` обязан
    // показать справку, а не ругаться на отсутствующий аргумент.
    if (!want_help and !want_version) try checkArgCount(parsed, diag);
    return parsed;
}

fn checkArgCount(p: Parsed, diag: ?*Diagnostics) Error!void {
    const n = p.args.len;
    const ok = switch (p.command.args) {
        .none => n == 0,
        .exact => |want| n == want,
        .minimum => |want| n >= want,
        .any, .passthrough => true,
    };
    if (ok) return;
    if (diag) |d| d.* = .{
        .command = p.command.name,
        .detail = switch (p.command.args) {
            .none => "accepts no arguments",
            .exact => |want| if (want == 1) "accepts exactly 1 argument" else "accepts a fixed number of arguments",
            .minimum => "requires at least one argument",
            else => "",
        },
    };
    return error.WrongArgCount;
}

fn setValue(gpa: Allocator, values: *std.ArrayList(Set), long: []const u8, v: Value) Allocator.Error!void {
    for (values.items) |*existing| {
        if (std.mem.eql(u8, existing.long, long)) {
            existing.value = v;
            return;
        }
    }
    try values.append(gpa, .{ .long = long, .value = v });
}

fn currentCount(values: []const Set, long: []const u8) usize {
    for (values) |v| {
        if (std.mem.eql(u8, v.long, long) and v.value == .counter) return v.value.counter;
    }
    return 0;
}

/// Ищет флаг в текущей команде и в её предках (persistent-флаги).
fn lookupFlag(path: []const *const Command, name: []const u8) ?Flag {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        const c = path[i];
        for (c.flags) |f| {
            // Собственные флаги команды видны только ей; persistent —
            // и всем потомкам.
            if (std.mem.eql(u8, f.long, name) and (i == path.len - 1 or f.persistent)) return f;
        }
    }
    return null;
}

fn lookupShort(path: []const *const Command, ch: u8) ?Flag {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        const c = path[i];
        for (c.flags) |f| {
            if (f.short == ch and (i == path.len - 1 or f.persistent)) return f;
        }
    }
    return null;
}

/// Похожие имена подкоманд: по префиксу либо по расстоянию правки ≤ 2.
fn suggest(gpa: Allocator, c: *const Command, typo: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (c.subcommands) |*sub| {
        if (sub.hidden) continue;
        if (std.mem.startsWith(u8, sub.name, typo) or
            std.mem.startsWith(u8, typo, sub.name) or
            editDistance(sub.name, typo) <= 2)
        {
            try out.append(gpa, sub.name);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Расстояние Левенштейна. Строки коротки (имена команд), поэтому хватает
/// двух строк матрицы фиксированного размера.
fn editDistance(a: []const u8, b: []const u8) usize {
    const max_len = 32;
    if (a.len > max_len or b.len > max_len) return max_len;

    var prev: [max_len + 1]usize = undefined;
    var cur: [max_len + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;

    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// ---- справка ---------------------------------------------------------------

/// Печатает справку по команде в форме, к которой приучил cobra.
pub fn writeHelp(gpa: Allocator, w: *Writer, path: []const *const Command) !void {
    const c = path[path.len - 1];
    const full = try fullName(gpa, path);
    defer gpa.free(full);

    if (c.long.len > 0) {
        try w.writeAll(c.long);
        try w.writeAll("\n\n");
    } else if (c.short.len > 0) {
        try w.print("{s}\n\n", .{c.short});
    }

    try w.writeAll("Usage:\n");
    if (c.subcommands.len > 0) {
        try w.print("  {s} [command]\n", .{full});
    } else {
        try w.print("  {s}", .{full});
        if (c.usage_args.len > 0) try w.print(" {s}", .{c.usage_args});
        if (c.flags.len > 0) try w.writeAll(" [flags]");
        try w.writeByte('\n');
    }

    if (visibleCount(c.subcommands) > 0) {
        try w.writeAll("\nAvailable Commands:\n");
        const width = maxNameWidth(c.subcommands);
        for (c.subcommands) |*sub| {
            if (sub.hidden) continue;
            try w.print("  {s}", .{sub.name});
            try padTo(w, sub.name.len, width + 2);
            try w.print("{s}\n", .{sub.short});
        }
    }

    // Собственные флаги команды и унаследованные показываются раздельно —
    // так читателю видно, что настраивает эта команда, а что весь envee.
    if (visibleFlagCount(c.flags) > 0 or path.len == 1) {
        try w.writeAll("\nFlags:\n");
        try writeFlags(w, c.flags, full, true, path.len == 1);
    }
    if (path.len > 1) {
        var inherited: std.ArrayList(Flag) = .empty;
        defer inherited.deinit(gpa);
        for (path[0 .. path.len - 1]) |ancestor| {
            for (ancestor.flags) |f| {
                if (f.persistent and !f.hidden) try inherited.append(gpa, f);
            }
        }
        if (inherited.items.len > 0) {
            try w.writeAll("\nGlobal Flags:\n");
            try writeFlags(w, inherited.items, full, false, false);
        }
    }

    if (visibleCount(c.subcommands) > 0) {
        try w.print("\nUse \"{s} [command] --help\" for more information about a command.\n", .{full});
    }
}

fn writeFlags(w: *Writer, flags: []const Flag, name: []const u8, with_help: bool, with_version: bool) !void {
    // Ширина колонки считается по всем строкам сразу, иначе описания
    // разъедутся.
    var width: usize = 0;
    for (flags) |f| {
        if (f.hidden) continue;
        width = @max(width, flagLabelLen(f));
    }
    width = @max(width, "-h, --help".len);
    if (with_version) width = @max(width, "    --version".len - 4);

    for (flags) |f| {
        if (f.hidden) continue;
        try writeFlagLine(w, f, width);
    }
    if (with_help) {
        var help_buf: [64]u8 = undefined;
        const help_text = std.fmt.bufPrint(&help_buf, "help for {s}", .{name}) catch "help";
        try writeFlagLine(w, .{ .long = "help", .short = 'h', .help = help_text }, width);
    }
    if (with_version) {
        try writeFlagLine(w, .{ .long = "version", .help = "version for envee" }, width);
    }
}

fn flagLabelLen(f: Flag) usize {
    var n = f.long.len + 2; // "--"
    if (f.kind == .string) n += " string".len;
    return n;
}

fn writeFlagLine(w: *Writer, f: Flag, width: usize) !void {
    if (f.short != 0) {
        try w.print("  -{c}, --{s}", .{ f.short, f.long });
    } else {
        try w.print("      --{s}", .{f.long});
    }
    var used = f.long.len + 2;
    if (f.kind == .string) {
        try w.writeAll(" string");
        used += " string".len;
    }
    try padTo(w, used, width + 3);
    try w.writeAll(f.help);
    if (f.kind == .string and f.kind.string.len > 0) {
        try w.print(" (default \"{s}\")", .{f.kind.string});
    }
    try w.writeByte('\n');
}

fn padTo(w: *Writer, used: usize, target: usize) !void {
    const n = if (target > used) target - used else 1;
    try w.splatByteAll(' ', n);
}

fn visibleCount(cmds: []const Command) usize {
    var n: usize = 0;
    for (cmds) |c| {
        if (!c.hidden) n += 1;
    }
    return n;
}

fn visibleFlagCount(flags: []const Flag) usize {
    var n: usize = 0;
    for (flags) |f| {
        if (!f.hidden) n += 1;
    }
    return n;
}

fn maxNameWidth(cmds: []const Command) usize {
    var n: usize = 0;
    for (cmds) |c| {
        if (!c.hidden) n = @max(n, c.name.len);
    }
    return n;
}

fn fullName(gpa: Allocator, path: []const *const Command) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |c, i| {
        if (i > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, c.name);
    }
    return out.toOwnedSlice(gpa);
}

/// Печатает ошибку разбора в том же виде, что и cobra.
pub fn writeError(w: *Writer, err: Error, diag: Diagnostics) !void {
    switch (err) {
        error.UnknownCommand => {
            try w.print("Error: unknown command \"{s}\" for \"{s}\"\n", .{ diag.token, diag.command });
            if (diag.suggestions.len > 0) {
                try w.writeAll("\nDid you mean this?\n");
                for (diag.suggestions) |s| try w.print("\t{s}\n", .{s});
            }
            try w.print("\nRun '{s} --help' for usage.\n", .{diag.command});
        },
        error.UnknownFlag => try w.print("Error: unknown flag: {s}\n", .{diag.token}),
        error.MissingFlagValue => try w.print("Error: flag needs an argument: {s}\n", .{diag.token}),
        error.WrongArgCount => try w.print("Error: {s} {s}\n", .{ diag.command, diag.detail }),
        error.OutOfMemory => try w.writeAll("Error: out of memory\n"),
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const test_root: Command = .{
    .name = "envee",
    .short = "Per-directory environment variable manager",
    .long = "envee loads environment variables from envee.toml.",
    .flags = &.{
        .{ .long = "config", .kind = .{ .string = "" }, .help = "path to envee.toml (default: auto-discover)", .persistent = true },
        .{ .long = "profile", .kind = .{ .string = "" }, .help = "profile to use (overrides $ENVEE_PROFILE)", .persistent = true },
        .{ .long = "log-level", .kind = .{ .string = "warn" }, .help = "log level: trace|debug|info|warn|error", .persistent = true },
        .{ .long = "quiet", .short = 'q', .help = "suppress non-essential output", .persistent = true },
        .{ .long = "verbose", .short = 'v', .kind = .counter, .help = "increase log verbosity (-v = info, -vv = debug)", .persistent = true },
        .{ .long = "debug", .help = "enable debug mode", .persistent = true },
    },
    .subcommands = &.{
        .{ .name = "eval", .usage_args = "<shell>", .short = "Print shell-specific export/unset commands", .args = .{ .exact = 1 } },
        .{ .name = "init", .usage_args = "<shell>", .short = "Generate shell hook code", .args = .{ .exact = 1 }, .flags = &.{
            .{ .long = "cached", .help = "write to cache file instead of stdout" },
        } },
        .{ .name = "exec", .usage_args = "-- <command> [args...]", .short = "Run a command with the loaded env", .args = .passthrough },
        .{ .name = "status", .short = "Show current envee state" },
        .{ .name = "secret", .short = "Manage secrets", .subcommands = &.{
            .{ .name = "set", .usage_args = "KEY=VALUE", .short = "Set a secret", .args = .{ .exact = 1 } },
            .{ .name = "list", .short = "List secrets" },
        } },
        .{ .name = "upgrade", .short = "Upgrade envee", .hidden = true },
    },
};

fn parseArgs(gpa: Allocator, argv: []const []const u8) Error!Parsed {
    return parse(gpa, &test_root, argv, null);
}

test "a bare invocation selects the root command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parseArgs(a, &.{});
    try testing.expectEqualStrings("envee", p.command.name);
    try testing.expectEqual(@as(usize, 0), p.args.len);
    try testing.expect(!p.help);
}

test "subcommands, including nested ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eval = try parseArgs(a, &.{ "eval", "bash" });
    try testing.expectEqualStrings("eval", eval.command.name);
    try testing.expectEqual(@as(usize, 1), eval.args.len);
    try testing.expectEqualStrings("bash", eval.args[0]);

    const nested = try parseArgs(a, &.{ "secret", "set", "K=V" });
    try testing.expectEqualStrings("set", nested.command.name);
    try testing.expectEqual(@as(usize, 3), nested.path.len);
    try testing.expectEqualStrings("envee secret set", try nested.commandPath(a));
    try testing.expectEqualStrings("K=V", nested.args[0]);
}

test "string flags, both spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spaced = try parseArgs(a, &.{ "--profile", "prod", "eval", "bash" });
    try testing.expectEqualStrings("prod", spaced.str("profile"));

    const equals = try parseArgs(a, &.{ "--profile=prod", "eval", "bash" });
    try testing.expectEqualStrings("prod", equals.str("profile"));

    // Значение с пробелами и знаком равенства внутри не разваливается.
    const tricky = try parseArgs(a, &.{"--config=/a b/envee.toml"});
    try testing.expectEqualStrings("/a b/envee.toml", tricky.str("config"));
    const with_eq = try parseArgs(a, &.{ "--config", "a=b" });
    try testing.expectEqualStrings("a=b", with_eq.str("config"));
}

test "an unset string flag falls back to its default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parseArgs(a, &.{"status"});
    try testing.expectEqualStrings("warn", p.str("log-level"));
    try testing.expectEqualStrings("", p.str("profile"));
}

test "flags work before and after the subcommand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try parseArgs(a, &.{ "--profile", "prod", "eval", "bash" });
    const after = try parseArgs(a, &.{ "eval", "--profile", "prod", "bash" });
    try testing.expectEqualStrings("prod", before.str("profile"));
    try testing.expectEqualStrings("prod", after.str("profile"));
    try testing.expectEqualStrings("bash", after.args[0]);
}

test "boolean and short flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const long = try parseArgs(a, &.{ "--quiet", "status" });
    try testing.expect(long.boolean("quiet"));

    const short = try parseArgs(a, &.{ "-q", "status" });
    try testing.expect(short.boolean("quiet"));
    try testing.expect(!short.boolean("debug"));
}

// В Go `-v` объявлен булевым, а читается как число: GetInt на булевом флаге
// возвращает ошибку, её отбрасывают, и значение остаётся нулём. То есть
// `-v` и `-vv` там не делают ничего.
test "verbose is a real counter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try parseArgs(a, &.{"status"})).count("verbose"));
    try testing.expectEqual(@as(usize, 1), (try parseArgs(a, &.{ "-v", "status" })).count("verbose"));
    try testing.expectEqual(@as(usize, 2), (try parseArgs(a, &.{ "-vv", "status" })).count("verbose"));
    try testing.expectEqual(@as(usize, 2), (try parseArgs(a, &.{ "-v", "-v", "status" })).count("verbose"));
    try testing.expectEqual(@as(usize, 3), (try parseArgs(a, &.{ "--verbose", "-vv" })).count("verbose"));
}

test "clustered short flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parseArgs(a, &.{ "-qv", "status" });
    try testing.expect(p.boolean("quiet"));
    try testing.expectEqual(@as(usize, 1), p.count("verbose"));
}

test "help is recognised anywhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try parseArgs(a, &.{"--help"})).help);
    try testing.expect((try parseArgs(a, &.{"-h"})).help);
    try testing.expect((try parseArgs(a, &.{ "eval", "--help" })).help);
    try testing.expect((try parseArgs(a, &.{ "secret", "set", "-h" })).help);
    try testing.expect((try parseArgs(a, &.{"--version"})).version);
}

// Справка важнее числа аргументов: `envee eval --help` обязан показать
// справку, а не ругаться на пропущенный аргумент.
test "help outranks the argument count check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parseArgs(a, &.{ "eval", "--help" });
    try testing.expect(p.help);
    try testing.expectEqualStrings("eval", p.command.name);
}

test "everything after a double dash is passed through verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parseArgs(a, &.{ "exec", "--", "ls", "-la", "--color", "/tmp" });
    try testing.expectEqualStrings("exec", p.command.name);
    try testing.expectEqual(@as(usize, 4), p.args.len);
    // Флаги команды НЕ разбираются: они принадлежат чужой программе.
    try testing.expectEqualStrings("-la", p.args[1]);
    try testing.expectEqualStrings("--color", p.args[2]);
    try testing.expect(!p.boolean("quiet"));
}

test "argument counts are enforced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(error.WrongArgCount, parse(a, &test_root, &.{"eval"}, &diag));
    try testing.expectEqualStrings("eval", diag.command);

    try testing.expectError(error.WrongArgCount, parse(a, &test_root, &.{ "eval", "bash", "extra" }, &diag));
    try testing.expectError(error.WrongArgCount, parse(a, &test_root, &.{ "status", "unexpected" }, &diag));
}

test "an unknown command is refused, with suggestions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(error.UnknownCommand, parse(a, &test_root, &.{"evl"}, &diag));
    try testing.expectEqualStrings("evl", diag.token);
    try testing.expectEqual(@as(usize, 1), diag.suggestions.len);
    try testing.expectEqualStrings("eval", diag.suggestions[0]);

    // Скрытые команды в подсказки не попадают, но вызвать их можно.
    diag = .{};
    try testing.expectError(error.UnknownCommand, parse(a, &test_root, &.{"upgrad"}, &diag));
    try testing.expectEqual(@as(usize, 0), diag.suggestions.len);
    const hidden = try parseArgs(a, &.{"upgrade"});
    try testing.expectEqualStrings("upgrade", hidden.command.name);
}

test "an unknown flag is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(error.UnknownFlag, parse(a, &test_root, &.{"--nosuch"}, &diag));
    try testing.expectEqualStrings("--nosuch", diag.token);
    try testing.expectError(error.UnknownFlag, parse(a, &test_root, &.{ "status", "-Z" }, &diag));
}

// Собственный флаг подкоманды не должен быть виден ни корню, ни соседям.
test "a subcommand's own flag does not leak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parseArgs(a, &.{ "init", "--cached", "bash" });
    try testing.expect(ok.boolean("cached"));

    var diag: Diagnostics = .{};
    try testing.expectError(error.UnknownFlag, parse(a, &test_root, &.{ "eval", "--cached", "bash" }, &diag));
    try testing.expectError(error.UnknownFlag, parse(a, &test_root, &.{"--cached"}, &diag));
}

test "a string flag without a value is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(error.MissingFlagValue, parse(a, &test_root, &.{"--profile"}, &diag));
    try testing.expectEqualStrings("--profile", diag.token);
}

test "edit distance" {
    try testing.expectEqual(@as(usize, 0), editDistance("eval", "eval"));
    try testing.expectEqual(@as(usize, 1), editDistance("eval", "evl"));
    try testing.expectEqual(@as(usize, 1), editDistance("eval", "evals"));
    try testing.expectEqual(@as(usize, 3), editDistance("eval", "vla"));
    try testing.expectEqual(@as(usize, 4), editDistance("eval", ""));
}

fn renderHelp(gpa: Allocator, argv: []const []const u8) ![]const u8 {
    const p = try parse(gpa, &test_root, argv, null);
    var aw: Writer.Allocating = .init(gpa);
    try writeHelp(gpa, &aw.writer, p.path);
    return aw.written();
}

test "root help lists commands and flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderHelp(a, &.{"--help"});
    try testing.expect(std.mem.indexOf(u8, out, "envee loads environment variables") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Usage:\n  envee [command]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Available Commands:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  eval    Print shell-specific") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-q, --quiet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(default \"warn\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--version") != null);
    // Скрытая команда в справке не показывается.
    try testing.expect(std.mem.indexOf(u8, out, "upgrade") == null);
}

test "subcommand help separates own flags from inherited ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderHelp(a, &.{ "init", "--help" });
    try testing.expect(std.mem.indexOf(u8, out, "Usage:\n  envee init <shell> [flags]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Flags:\n      --cached") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Global Flags:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--log-level") != null);
    // Версия — свойство корня, у подкоманды её быть не должно.
    try testing.expect(std.mem.indexOf(u8, out, "--version") == null);
}

test "help for a command group lists its subcommands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderHelp(a, &.{ "secret", "--help" });
    try testing.expect(std.mem.indexOf(u8, out, "Usage:\n  envee secret [command]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  set   Set a secret") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Use \"envee secret [command] --help\"") != null);
}

test "error rendering follows the familiar shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: Writer.Allocating = .init(a);
    try writeError(&aw.writer, error.UnknownCommand, .{
        .token = "evl",
        .command = "envee",
        .suggestions = &.{"eval"},
    });
    try testing.expectEqualStrings(
        "Error: unknown command \"evl\" for \"envee\"\n" ++
            "\nDid you mean this?\n\teval\n" ++
            "\nRun 'envee --help' for usage.\n",
        aw.written(),
    );

    var aw2: Writer.Allocating = .init(a);
    try writeError(&aw2.writer, error.UnknownFlag, .{ .token = "--nosuch" });
    try testing.expectEqualStrings("Error: unknown flag: --nosuch\n", aw2.written());
}
