//! `envee import [.envrc]` — переводит `.envrc` direnv в `envee.toml`.
//!
//! `.envrc` не исполняется: это bash, и запустить его ради конвертации
//! значило бы выполнить непроверенный код — ровно то, от чего envee уходит.
//! Вместо этого строки разбираются по одной. Узнаваемые формы (`export`,
//! `PATH_add`, `dotenv`, `watch_file`, `unset`, `source_up`) переводятся;
//! всё остальное — подстановки команд, условия, циклы, `use nix` — дословно
//! уходит в блок «MANUAL REVIEW» в начале файла. Молча потерять строку хуже,
//! чем показать её: пользователь должен видеть, что именно не переехало.
//!
//! Команда пишет файл рядом с `.envrc` и не трогает сам `.envrc`, поэтому
//! резервная копия, о которой говорит ADR-0013, не нужна.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const config = @import("../config.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const Ctx = context.Ctx;

pub const Error = context.Error;

pub const Manual = struct {
    line: usize,
    text: []const u8,
};

pub const Converted = struct {
    toml: []const u8,
    vars: usize,
    path: usize,
    files: usize,
    manual: []const Manual,
};

const FileEntry = struct { path: []const u8, required: bool };

/// Значение переменной: строка-шаблон или `false` (снять переменную).
const Value = union(enum) { str: []const u8, unset };

pub fn convert(a: Allocator, src: []const u8, source_name: []const u8) Allocator.Error!Converted {
    var vars: std.StringArrayHashMapUnmanaged(Value) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(FileEntry) = .empty;
    var watch: std.ArrayList([]const u8) = .empty;
    var manual: std.ArrayList(Manual) = .empty;

    var it = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const handled = try convertLine(a, line, &vars, &path, &files, &watch);
        if (!handled) try manual.append(a, .{ .line = n, .text = line });
    }

    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    write(w, source_name, vars, path.items, files.items, watch.items, manual.items) catch return error.OutOfMemory;
    return .{
        .toml = try out.toOwnedSlice(),
        .vars = vars.count(),
        .path = path.items.len,
        .files = files.items.len,
        .manual = manual.items,
    };
}

/// Переводит одну строку. `false` — строку перевести нельзя, и её нужно
/// показать человеку. Ничего не добавляет, пока не убедится, что вся строка
/// понята: половина `export A=1 B=$(x)` хуже, чем ничего.
fn convertLine(
    a: Allocator,
    line: []const u8,
    vars: *std.StringArrayHashMapUnmanaged(Value),
    path: *std.ArrayList([]const u8),
    files: *std.ArrayList(FileEntry),
    watch: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    const words = (try splitWords(a, line)) orelse return false;
    if (words.len == 0) return true;
    const cmd = words[0];
    const rest = words[1..];

    if (std.mem.eql(u8, cmd, "export")) {
        const Pending = struct { name: []const u8, value: []const u8 };
        var pending: std.ArrayList(Pending) = .empty;
        var prepend: std.ArrayList([]const u8) = .empty;
        for (rest) |word| {
            // `export A` без значения экспортирует уже заданную в том же
            // .envrc переменную — у нас все переменные и так экспортируются.
            const eq = std.mem.indexOfScalar(u8, word, '=') orelse {
                if (!isName(word)) return false;
                continue;
            };
            const name = word[0..eq];
            const value = word[eq + 1 ..];
            if (!isName(name)) return false;
            if (std.mem.eql(u8, name, "PATH")) {
                if (!try splitPath(a, value, &prepend)) return false;
                continue;
            }
            if (std.mem.startsWith(u8, name, "ENVEE_")) return false;
            try pending.append(a, .{ .name = name, .value = value });
        }
        for (pending.items) |p| try vars.put(a, p.name, .{ .str = p.value });
        try path.appendSlice(a, prepend.items);
        return true;
    }
    if (std.mem.eql(u8, cmd, "unset")) {
        for (rest) |name| if (!isName(name)) return false;
        for (rest) |name| try vars.put(a, name, .unset);
        return true;
    }
    if (std.mem.eql(u8, cmd, "PATH_add")) {
        try path.appendSlice(a, rest);
        return true;
    }
    if (std.mem.eql(u8, cmd, "path_add")) {
        if (rest.len < 1 or !std.mem.eql(u8, rest[0], "PATH")) return false;
        try path.appendSlice(a, rest[1..]);
        return true;
    }
    if (std.mem.eql(u8, cmd, "dotenv") or std.mem.eql(u8, cmd, "dotenv_if_exists")) {
        if (rest.len > 1) return false;
        const required = std.mem.eql(u8, cmd, "dotenv");
        try files.append(a, .{ .path = if (rest.len == 1) rest[0] else ".env", .required = required });
        return true;
    }
    if (std.mem.eql(u8, cmd, "watch_file")) {
        try watch.appendSlice(a, rest);
        return true;
    }
    // envee и так поднимается по родительским каталогам и склеивает их
    // конфиги, так что эти строки просто не нужны.
    if (std.mem.eql(u8, cmd, "source_up") or std.mem.eql(u8, cmd, "source_up_if_exists")) {
        return rest.len == 0;
    }
    return false;
}

/// `a:b:$PATH` → каталоги a и b в начало PATH. Что-то после `$PATH`
/// (дописать в конец) или PATH без `$PATH` (заменить целиком) envee не
/// выражает — такая строка уходит на ручной разбор.
fn splitPath(a: Allocator, value: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!bool {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ':');
    var seen_path = false;
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "{{env.PATH}}")) {
            seen_path = true;
            continue;
        }
        if (seen_path or part.len == 0) return false;
        try parts.append(a, part);
    }
    if (!seen_path) return false;
    try out.appendSlice(a, parts.items);
    return true;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Делит строку на слова по правилам bash для того подмножества, которое
/// переводится без исполнения: кавычки, `\`, `$NAME`, `${NAME}`, `~`.
/// Переменные становятся шаблонами envee (`{{env.NAME}}`, `$PWD` —
/// `{{config_root}}`: direnv исполняет .envrc в его каталоге). `null` —
/// в строке есть то, что требует bash: `$(...)`, обратные кавычки,
/// `${X:-y}`, `;`, `|`, `&&`, перенаправления, незакрытая кавычка.
pub fn splitWords(a: Allocator, line: []const u8) Allocator.Error!?[]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t' => {
                if (in_word) try words.append(a, try cur.toOwnedSlice(a));
                in_word = false;
                i += 1;
            },
            '#' => {
                if (!in_word) break;
                try cur.append(a, c);
                i += 1;
            },
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return null;
                const lit = line[i + 1 .. end];
                // `{{` в литерале envee принял бы за шаблон.
                if (std.mem.indexOf(u8, lit, "{{") != null) return null;
                try cur.appendSlice(a, lit);
                in_word = true;
                i = end + 1;
            },
            '"' => {
                i += 1;
                while (true) {
                    if (i >= line.len) return null;
                    const d = line[i];
                    if (d == '"') break;
                    if (d == '`') return null;
                    if (d == '\\' and i + 1 < line.len and std.mem.indexOfScalar(u8, "$`\"\\", line[i + 1]) != null) {
                        try cur.append(a, line[i + 1]);
                        i += 2;
                    } else if (d == '$') {
                        i = (try expand(a, line, i, &cur)) orelse return null;
                    } else if (d == '{' and i + 1 < line.len and line[i + 1] == '{') {
                        return null;
                    } else {
                        try cur.append(a, d);
                        i += 1;
                    }
                }
                in_word = true;
                i += 1;
            },
            '\\' => {
                // `\` в конце строки — продолжение на следующей; такие
                // конструкции разбирать построчно нельзя.
                if (i + 1 >= line.len) return null;
                try cur.append(a, line[i + 1]);
                in_word = true;
                i += 2;
            },
            '$' => {
                i = (try expand(a, line, i, &cur)) orelse return null;
                in_word = true;
            },
            '~' => {
                // Как в bash: `~` раскрывается в начале слова и после `=` или
                // `:` в присваивании (`export PATH=~/bin:$PATH`).
                const at_start = !in_word or line[i - 1] == '=' or line[i - 1] == ':';
                if (at_start and (i + 1 == line.len or line[i + 1] == '/' or line[i + 1] == ':' or line[i + 1] == ' '))
                    try cur.appendSlice(a, "{{env.HOME}}")
                else
                    try cur.append(a, c);
                in_word = true;
                i += 1;
            },
            ';', '&', '|', '<', '>', '(', ')', '`' => return null,
            '{' => {
                if (i + 1 < line.len and line[i + 1] == '{') return null;
                try cur.append(a, c);
                in_word = true;
                i += 1;
            },
            else => {
                try cur.append(a, c);
                in_word = true;
                i += 1;
            },
        }
    }
    if (in_word) try words.append(a, try cur.toOwnedSlice(a));
    return try words.toOwnedSlice(a);
}

/// Разворачивает `$NAME` или `${NAME}` с позиции `i` (там стоит `$`) и
/// возвращает позицию после него. `null` — форма, которую без bash не
/// посчитать.
fn expand(a: Allocator, line: []const u8, i: usize, cur: *std.ArrayList(u8)) Allocator.Error!?usize {
    var j = i + 1;
    if (j >= line.len) {
        try cur.append(a, '$');
        return j;
    }
    var name: []const u8 = undefined;
    if (line[j] == '{') {
        const end = std.mem.indexOfScalarPos(u8, line, j + 1, '}') orelse return null;
        name = line[j + 1 .. end];
        j = end + 1;
    } else {
        const start = j;
        while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) j += 1;
        name = line[start..j];
        if (name.len == 0) {
            // `$` перед пробелом или кавычкой — просто символ; `$(`, `$?`,
            // `$@` и прочее — работа bash.
            if (line[j] == ' ' or line[j] == '"' or line[j] == '\t') {
                try cur.append(a, '$');
                return j;
            }
            return null;
        }
    }
    if (!isName(name)) return null;
    if (std.mem.eql(u8, name, "PWD")) {
        try cur.appendSlice(a, "{{config_root}}");
    } else {
        try cur.print(a, "{{{{env.{s}}}}}", .{name});
    }
    return j;
}

fn write(
    w: *Writer,
    source_name: []const u8,
    vars: std.StringArrayHashMapUnmanaged(Value),
    path: []const []const u8,
    files: []const FileEntry,
    watch: []const []const u8,
    manual: []const Manual,
) Writer.Error!void {
    try w.print(
        \\# Imported from {s} by `envee import`.
        \\# Review it, then run `envee trust`.
        \\
    , .{source_name});
    if (manual.len > 0) {
        try w.writeAll(
            \\#
            \\# MANUAL REVIEW: these lines have no automatic equivalent and were not
            \\# imported. Rewrite them as envee.toml keys, a .env file loaded with
            \\# _.file, or a secret plugin ({ source = "...", ref = "..." }).
            \\#
            \\
        );
        for (manual) |m| try w.print("#   {s}:{d}: {s}\n", .{ source_name, m.line, m.text });
    }
    try w.writeAll("\nschema = \"" ++ config.schema_version ++ "\"\n\n[env]\n");
    var it = vars.iterator();
    while (it.next()) |e| {
        try w.print("{s} = ", .{e.key_ptr.*});
        switch (e.value_ptr.*) {
            .str => |s| try writeString(w, s),
            .unset => try w.writeAll("false"),
        }
        try w.writeAll("\n");
    }
    if (path.len > 0) {
        try w.writeAll("_.path = [");
        for (path, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try writeString(w, p);
        }
        try w.writeAll("]\n");
    }
    if (files.len > 0) {
        try w.writeAll("_.file = [\n");
        for (files) |f| {
            try w.writeAll("  { path = ");
            try writeString(w, f.path);
            try w.print(", required = {} }},\n", .{f.required});
        }
        try w.writeAll("]\n");
    }
    if (watch.len > 0) {
        try w.writeAll("watch = [");
        for (watch, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try writeString(w, p);
        }
        try w.writeAll("]\n");
    }
}

/// Базовая строка TOML.
fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11...31, 127 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const arg = if (parsed.args.len > 0) parsed.args[0] else ".envrc";
    const src_path = try std.fs.path.resolve(ctx.arena, &.{ ctx.cwd, arg });
    const S = struct {
        var kv: [1]errs.KV = undefined;
    };

    const src = std.Io.Dir.cwd().readFileAlloc(ctx.io, src_path, ctx.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            S.kv = .{.{ .key = "path", .value = src_path }};
            return errs.fail(.{
                .code = .e012,
                .summary = try std.fmt.allocPrint(ctx.arena, "cannot read {s}: {s}", .{ arg, @errorName(err) }),
                .context = &S.kv,
                .hint = "Pass the path to the .envrc to import: envee import path/to/.envrc",
            }, error.FileNotFound);
        },
    };

    const conv = try convert(ctx.arena, src, std.fs.path.basename(src_path));

    if (parsed.boolean("stdout")) {
        try ctx.stdout.writeAll(conv.toml);
        return;
    }

    const dst = try std.fs.path.join(ctx.arena, &.{ std.fs.path.dirname(src_path) orelse ".", "envee.toml" });
    if (!parsed.boolean("force")) {
        if (std.Io.Dir.cwd().statFile(ctx.io, dst, .{})) |_| {
            S.kv = .{.{ .key = "path", .value = dst }};
            return errs.fail(.{
                .code = .e003,
                .summary = "envee.toml already exists",
                .context = &S.kv,
                .hint = "Pass --force to overwrite it, or --stdout to print the result instead.",
            }, error.ConfigValidation);
        } else |_| {}
    }
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dst, .data = conv.toml }) catch |err| {
        S.kv = .{.{ .key = "path", .value = dst }};
        return errs.fail(.{
            .code = .e013,
            .summary = try std.fmt.allocPrint(ctx.arena, "cannot write envee.toml: {s}", .{@errorName(err)}),
            .context = &S.kv,
        }, error.PermissionDenied);
    };

    const w = ctx.stderr;
    try w.print("Wrote {s}\n  variables:  {d}\n  PATH adds:  {d}\n  files:      {d}\n", .{ dst, conv.vars, conv.path, conv.files });
    if (conv.manual.len > 0) {
        try w.print("  manual:     {d} line(s) need review — listed at the top of envee.toml\n", .{conv.manual.len});
    }
    try w.writeAll(
        \\
        \\Next steps:
        \\  1. Review envee.toml
        \\  2. envee check && envee trust
        \\  3. Remove .envrc once direnv is no longer needed
        \\
    );
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

fn convertOk(a: Allocator, src: []const u8) !Converted {
    const c = try convert(a, src, ".envrc");
    // Результат обязан быть конфигом, который envee сам же и прочитает.
    var diag: config.Diagnostics = .{};
    _ = config.parseBytes(a, "envee.toml", c.toml, &diag) catch |err| {
        std.debug.print("generated invalid envee.toml ({s}):\n{s}\n", .{ @errorName(err), c.toml });
        return err;
    };
    return c;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "exports with every kind of quoting become strings and templates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try convertOk(arena.allocator(),
        \\export A=plain
        \\export B='single $NOT'
        \\export C="double $HOME and ${USER}"
        \\export D=$PWD/data E=x\ y
        \\export F="quote \" and \\ back"
        \\export G=~/cache
    );
    try testing.expectEqual(@as(usize, 7), c.vars);
    try testing.expectEqual(@as(usize, 0), c.manual.len);
    try testing.expect(contains(c.toml, "A = \"plain\""));
    try testing.expect(contains(c.toml, "B = \"single $NOT\""));
    try testing.expect(contains(c.toml, "C = \"double {{env.HOME}} and {{env.USER}}\""));
    try testing.expect(contains(c.toml, "D = \"{{config_root}}/data\""));
    try testing.expect(contains(c.toml, "E = \"x y\""));
    try testing.expect(contains(c.toml, "F = \"quote \\\" and \\\\ back\""));
    try testing.expect(contains(c.toml, "G = \"{{env.HOME}}/cache\""));
}

test "directives map to _.path, _.file, watch and unset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try convertOk(arena.allocator(),
        \\# comment
        \\source_up
        \\PATH_add bin
        \\path_add PATH node_modules/.bin
        \\export PATH=$PWD/tools:$PATH
        \\dotenv
        \\dotenv_if_exists .env.local
        \\watch_file package.json
        \\unset DEBUG
    );
    try testing.expectEqual(@as(usize, 0), c.manual.len);
    try testing.expect(contains(c.toml, "_.path = [\"bin\", \"node_modules/.bin\", \"{{config_root}}/tools\"]"));
    try testing.expect(contains(c.toml, "{ path = \".env\", required = true }"));
    try testing.expect(contains(c.toml, "{ path = \".env.local\", required = false }"));
    try testing.expect(contains(c.toml, "watch = [\"package.json\"]"));
    try testing.expect(contains(c.toml, "DEBUG = false"));
}

test "anything that needs bash is listed for manual review, never half-imported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try convertOk(arena.allocator(),
        \\export OK=1
        \\export A=1 B=$(git rev-parse HEAD)
        \\export C=`date`
        \\export D=${X:-fallback}
        \\use nix
        \\if [ -f x ]; then
        \\export E=1 && echo hi
        \\export PATH=$PATH:/late
        \\export ENVEE_PROFILE=prod
        \\export F='{{config_root}}'
        \\export G="unterminated
    );
    try testing.expectEqual(@as(usize, 1), c.vars);
    try testing.expectEqual(@as(usize, 10), c.manual.len);
    try testing.expectEqual(@as(usize, 2), c.manual[0].line);
    try testing.expect(!contains(c.toml, "\nA = "));
    try testing.expect(contains(c.toml, "#   .envrc:5: use nix"));
}

test "the last assignment wins, as it would in bash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try convertOk(arena.allocator(), "export A=1\nexport A=2\n");
    try testing.expectEqual(@as(usize, 1), c.vars);
    try testing.expect(contains(c.toml, "A = \"2\""));
}

test "import writes envee.toml next to .envrc and refuses to overwrite it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.writeFile(a, ".envrc", "export GREETING=hello\n");

    _ = try harness.run(a, tmp, &.{"import"}, &.{});
    const out = try harness.run(a, tmp, &.{"resolve"}, &.{});
    try testing.expect(contains(out, "GREETING=hello"));

    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{"import"}, &.{}));
    _ = try harness.run(a, tmp, &.{ "import", "--force" }, &.{});
}
