//! Минимальный шаблонизатор envee.
//!
//! Синтаксис: `{{ expr | filter | filter(args) }}`
//!
//! Выражения: `config_root`, `profile`, `cwd`, `env.X`, а также голое имя,
//! которое ищется там же, где `env.X`.
//!
//! Фильтры: `upper`, `lower`, `trim`, `default("...")`, `abspath`,
//! `realpath`, `dirname`, `basename`, `quote`.
//!
//! ВНИМАНИЕ. Go-эталон в шапке пакета обещает ещё `json` и `base64`, но в
//! `applyFilter` их нет — на них он возвращает «unknown filter». Здесь
//! повторено поведение, а не документация: расхождение записано в
//! docs/zig-rewrite-steps.md, раздел «Найдено в Go».
//!
//! Порт `internal/template/template.go`. См. docs/adr/0011-template-engine.md.
//!
//! Владение: `render` и `extractVarRefs` выделяют результат в переданном
//! аллокаторе; `Context` ничем не владеет.

const std = @import("std");
const Allocator = std.mem.Allocator;

const env = @import("env.zig");
const escape = @import("shell/escape.zig");

/// Окружение вычисления шаблона.
pub const Context = struct {
    config_root: []const u8 = "",
    profile: []const u8 = "",
    cwd: []const u8 = "",
    /// Уже разрешённые переменные envee (приоритетный источник).
    vars: ?*const env.Map = null,
    /// Исходное окружение процесса.
    os_env: ?*const env.Map = null,

    fn lookup(ctx: Context, key: []const u8) ?[]const u8 {
        if (ctx.vars) |m| {
            if (m.get(key)) |v| return v;
        }
        if (ctx.os_env) |m| {
            if (m.get(key)) |v| return v;
        }
        return null;
    }
};

/// Что именно не сложилось. Error set в Zig не носит нагрузки, поэтому
/// подробности едут отдельно. На шаге 8 сольётся с errs.zig.
pub const Diagnostics = struct {
    /// Смещение начала проблемного `{{` во входной строке.
    offset: usize = 0,
    /// Имя переменной или фильтра, вызвавшего ошибку.
    name: []const u8 = "",
};

pub const Error = error{
    UnterminatedTemplate,
    UnknownVariable,
    UnknownFilter,
    MissingClosingParen,
} || Allocator.Error;

/// Ошибки фильтров, которым нужна файловая система.
pub const RenderError = Error || std.Io.Dir.RealPathFileError || std.process.CurrentPathAllocError;

/// Подставляет значения в шаблон.
///
/// `io` нужен только фильтрам `abspath` и `realpath`; для шаблонов без них
/// можно передать любой Io.
pub fn render(
    gpa: Allocator,
    io: std.Io,
    tpl: []const u8,
    ctx: Context,
    diag: ?*Diagnostics,
) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < tpl.len) {
        if (i + 1 < tpl.len and tpl[i] == '{' and tpl[i + 1] == '{') {
            const end = std.mem.indexOf(u8, tpl[i + 2 ..], "}}") orelse {
                if (diag) |d| d.offset = i;
                return error.UnterminatedTemplate;
            };
            const expr = std.mem.trim(u8, tpl[i + 2 ..][0..end], " \t\r\n");
            const value = try evalExpr(gpa, io, expr, ctx, diag);
            defer gpa.free(value);
            out.writer.writeAll(value) catch return error.OutOfMemory;
            i += 2 + end + 2;
            continue;
        }
        out.writer.writeByte(tpl[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Вычисляет одно выражение `{{ ... }}` вместе с цепочкой фильтров.
fn evalExpr(
    gpa: Allocator,
    io: std.Io,
    expr: []const u8,
    ctx: Context,
    diag: ?*Diagnostics,
) RenderError![]u8 {
    var parts = std.mem.splitScalar(u8, expr, '|');
    const head = std.mem.trim(u8, parts.first(), " \t");

    // Наличие фильтра `default(...)` меняет обработку неизвестной
    // переменной: вместо ошибки берётся пустая строка, которую фильтр потом
    // и заменит. Именно `default(` — голое `| default` не считается.
    var has_default = false;
    {
        var scan = std.mem.splitScalar(u8, expr, '|');
        _ = scan.first();
        while (scan.next()) |f| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, f, " \t"), "default(")) {
                has_default = true;
                break;
            }
        }
    }

    var value: []u8 = blk: {
        if (std.mem.eql(u8, head, "config_root")) break :blk try gpa.dupe(u8, ctx.config_root);
        if (std.mem.eql(u8, head, "profile")) break :blk try gpa.dupe(u8, ctx.profile);
        if (std.mem.eql(u8, head, "cwd")) break :blk try gpa.dupe(u8, ctx.cwd);

        // `env.X` и голое имя ищутся одинаково: сначала среди уже
        // разрешённых переменных, затем в окружении процесса.
        const key = if (std.mem.startsWith(u8, head, "env.")) head[4..] else head;
        if (ctx.lookup(key)) |v| break :blk try gpa.dupe(u8, v);
        if (has_default) break :blk try gpa.dupe(u8, "");
        if (diag) |d| d.name = head;
        return error.UnknownVariable;
    };
    errdefer gpa.free(value);

    while (parts.next()) |raw_filter| {
        const f = std.mem.trim(u8, raw_filter, " \t");
        var args_buf: ArgsBuf = undefined;
        const parsed = try parseFilter(f, &args_buf, diag);
        const next = try applyFilter(gpa, io, parsed, value, diag);
        gpa.free(value);
        value = next;
    }
    return value;
}

const Filter = struct {
    name: []const u8,
    /// Аргументы как есть, без снятия кавычек. Указывают в буфер,
    /// принадлежащий вызывающему, — см. parseFilter.
    args: []const []const u8,
};

/// Максимум аргументов у фильтра. Больше одного пока не использует ни один,
/// запас взят с потолка; лишние аргументы отбрасываются.
const max_filter_args = 4;
const ArgsBuf = [max_filter_args][]const u8;

/// Разбирает вызов фильтра на имя и аргументы.
///
/// Буфер под аргументы принадлежит ВЫЗЫВАЮЩЕМУ и обязан пережить
/// возвращённый Filter: срез `args` указывает внутрь него. Держать буфер
/// полем самой структуры нельзя — при возврате по значению срез указывал бы
/// на умерший кадр стека.
fn parseFilter(s: []const u8, buf: *ArgsBuf, diag: ?*Diagnostics) Error!Filter {
    const open = std.mem.indexOfScalar(u8, s, '(') orelse {
        return .{ .name = std.mem.trim(u8, s, " \t"), .args = &.{} };
    };
    if (!std.mem.endsWith(u8, s, ")")) {
        if (diag) |d| d.name = s;
        return error.MissingClosingParen;
    }
    const name = std.mem.trim(u8, s[0..open], " \t");

    const arg_str = s[open + 1 .. s.len - 1];
    if (arg_str.len == 0) return .{ .name = name, .args = &.{} };

    // Наивное разбиение по запятой: вложенные скобки и экранированные
    // запятые не поддерживаются, ровно как в Go.
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, arg_str, ',');
    while (it.next()) |a| {
        if (n == buf.len) break;
        buf[n] = std.mem.trim(u8, a, " \t");
        n += 1;
    }
    return .{ .name = name, .args = buf[0..n] };
}

fn applyFilter(
    gpa: Allocator,
    io: std.Io,
    f: Filter,
    input: []const u8,
    diag: ?*Diagnostics,
) RenderError![]u8 {
    if (std.mem.eql(u8, f.name, "upper")) {
        const out = try gpa.alloc(u8, input.len);
        return std.ascii.upperString(out, input);
    }
    if (std.mem.eql(u8, f.name, "lower")) {
        const out = try gpa.alloc(u8, input.len);
        return std.ascii.lowerString(out, input);
    }
    if (std.mem.eql(u8, f.name, "trim")) {
        return gpa.dupe(u8, std.mem.trim(u8, input, " \t\n\r\x0b\x0c"));
    }
    if (std.mem.eql(u8, f.name, "default")) {
        if (input.len > 0) return gpa.dupe(u8, input);
        if (f.args.len == 0) return gpa.dupe(u8, "");
        return gpa.dupe(u8, unquote(f.args[0]));
    }
    if (std.mem.eql(u8, f.name, "abspath")) {
        return absPath(gpa, io, input);
    }
    if (std.mem.eql(u8, f.name, "realpath")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(io, input, &buf);
        return gpa.dupe(u8, buf[0..n]);
    }
    if (std.mem.eql(u8, f.name, "dirname")) {
        return dirname(gpa, input);
    }
    if (std.mem.eql(u8, f.name, "basename")) {
        return gpa.dupe(u8, basename(input));
    }
    if (std.mem.eql(u8, f.name, "quote")) {
        return escape.singleQuote(gpa, input);
    }
    if (diag) |d| d.name = f.name;
    return error.UnknownFilter;
}

/// Снимает окружающие кавычки со строкового литерала аргумента.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

// ---- POSIX-семантика путей как в Go ----------------------------------------
//
// std.fs.path в Zig отвечает на те же вопросы иначе: dirname возвращает null
// там, где Go возвращает "." или "/". Фильтры обязаны совпадать с Go, поэтому
// здесь воспроизведены filepath.Clean, filepath.Dir и filepath.Base.

fn isSep(c: u8) bool {
    return c == '/';
}

/// Лексическая нормализация пути, эквивалент Go filepath.Clean.
fn clean(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    if (path.len == 0) return gpa.dupe(u8, ".");

    const rooted = isSep(path[0]);
    const n = path.len;
    var out = try gpa.alloc(u8, path.len + 1);
    errdefer gpa.free(out);
    var w: usize = 0;
    var r: usize = 0;
    var dotdot: usize = 0;

    if (rooted) {
        out[w] = '/';
        w += 1;
        r = 1;
        dotdot = 1;
    }

    while (r < n) {
        if (isSep(path[r])) {
            r += 1;
        } else if (path[r] == '.' and (r + 1 == n or isSep(path[r + 1]))) {
            // Элемент "." ничего не значит.
            r += 1;
        } else if (path[r] == '.' and r + 1 < n and path[r + 1] == '.' and
            (r + 2 == n or isSep(path[r + 2])))
        {
            r += 2;
            if (w > dotdot) {
                // Съедаем предыдущий элемент.
                w -= 1;
                while (w > dotdot and !isSep(out[w])) w -= 1;
            } else if (!rooted) {
                // ".." в начале относительного пути сократить не с чем.
                if (w > 0) {
                    out[w] = '/';
                    w += 1;
                }
                out[w] = '.';
                out[w + 1] = '.';
                w += 2;
                dotdot = w;
            }
        } else {
            if ((rooted and w != 1) or (!rooted and w != 0)) {
                out[w] = '/';
                w += 1;
            }
            while (r < n and !isSep(path[r])) : (r += 1) {
                out[w] = path[r];
                w += 1;
            }
        }
    }

    if (w == 0) {
        gpa.free(out);
        return gpa.dupe(u8, ".");
    }
    return gpa.realloc(out, w);
}

/// Эквивалент Go filepath.Dir: всё, кроме последнего элемента, нормализовано.
fn dirname(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var i: isize = @as(isize, @intCast(path.len)) - 1;
    while (i >= 0 and !isSep(path[@intCast(i)])) i -= 1;
    const cut = path[0..@intCast(i + 1)];
    return clean(gpa, cut);
}

/// Эквивалент Go filepath.Base: последний элемент пути.
fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var p = path;
    while (p.len > 0 and isSep(p[p.len - 1])) p = p[0 .. p.len - 1];
    var i: isize = @as(isize, @intCast(p.len)) - 1;
    while (i >= 0 and !isSep(p[@intCast(i)])) i -= 1;
    if (i >= 0) p = p[@intCast(i + 1)..];
    if (p.len == 0) return "/";
    return p;
}

/// Эквивалент Go filepath.Abs.
fn absPath(gpa: Allocator, io: std.Io, path: []const u8) RenderError![]u8 {
    if (path.len > 0 and isSep(path[0])) return clean(gpa, path);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path });
    defer gpa.free(joined);
    return clean(gpa, joined);
}

/// Имена переменных, на которые ссылается шаблон.
///
/// `"{{config_root}}/logs/{{profile}}.log"` даёт `["config_root", "profile"]`.
/// Префикс `env.` снимается: переменные ссылаются на другие переменные в той
/// же области. Нужен directive для поиска циклов.
///
/// Незакрытый `{{` не ошибка: возвращается то, что успели собрать, как в Go.
pub fn extractVarRefs(gpa: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer refs.deinit(gpa);

    var i: usize = 0;
    while (i < s.len) {
        if (i + 1 < s.len and s[i] == '{' and s[i + 1] == '{') {
            const end = std.mem.indexOf(u8, s[i + 2 ..], "}}") orelse break;
            var expr = std.mem.trim(u8, s[i + 2 ..][0..end], " \t\r\n");
            if (std.mem.indexOfScalar(u8, expr, '|')) |pipe| {
                expr = std.mem.trim(u8, expr[0..pipe], " \t\r\n");
            }
            if (std.mem.startsWith(u8, expr, "env.")) expr = expr[4..];
            try refs.append(gpa, expr);
            i += 2 + end + 2;
            continue;
        }
        i += 1;
    }
    return refs.toOwnedSlice(gpa);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const test_io = std.testing.io;

fn expectRender(ctx: Context, tpl: []const u8, want: []const u8) !void {
    const got = try render(testing.allocator, test_io, tpl, ctx, null);
    defer testing.allocator.free(got);
    testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("template: {s}\n", .{tpl});
        return err;
    };
}

test "a template without expressions is copied through" {
    try expectRender(.{}, "hello world", "hello world");
    try expectRender(.{}, "", "");
    try expectRender(.{}, "{ single brace }", "{ single brace }");
}

test "variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vars: env.Map = .empty;
    try vars.set(a, "MY_VAR", "value");
    var os_env: env.Map = .empty;
    try os_env.set(a, "OS_ONLY", "from-os");
    try os_env.set(a, "MY_VAR", "shadowed");

    const ctx: Context = .{
        .config_root = "/home/user/proj",
        .profile = "dev",
        .cwd = "/tmp/here",
        .vars = &vars,
        .os_env = &os_env,
    };

    try expectRender(ctx, "{{config_root}}", "/home/user/proj");
    try expectRender(ctx, "{{profile}}", "dev");
    try expectRender(ctx, "{{cwd}}", "/tmp/here");
    try expectRender(ctx, "{{env.MY_VAR}}", "value");
    try expectRender(ctx, "{{env.OS_ONLY}}", "from-os");
    // Разрешённые переменные перекрывают окружение процесса.
    try expectRender(ctx, "{{MY_VAR}}", "value");
    try expectRender(ctx, "prefix-{{config_root}}-suffix", "prefix-/home/user/proj-suffix");
    try expectRender(ctx, "{{config_root}}/logs/{{profile}}.log", "/home/user/proj/logs/dev.log");
    // Пробелы внутри скобок не значимы.
    try expectRender(ctx, "{{  profile  }}", "dev");
}

test "filters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vars: env.Map = .empty;
    try vars.set(a, "UNSET_VAR", "");
    try vars.set(a, "PADDED", "  spaced  ");
    const ctx: Context = .{ .config_root = "/home/user", .profile = "dev", .vars = &vars };

    try expectRender(ctx, "{{profile | upper}}", "DEV");
    try expectRender(ctx, "{{profile | lower}}", "dev");
    try expectRender(ctx, "{{config_root | upper}}", "/HOME/USER");
    try expectRender(ctx, "{{PADDED | trim}}", "spaced");
    // Переменная есть, но пустая — умолчание срабатывает.
    try expectRender(ctx, "{{env.UNSET_VAR | default('fallback')}}", "fallback");
    // Переменной нет вовсе — default(...) в цепочке отменяет ошибку.
    try expectRender(ctx, "{{env.SET_VAR | default('fb')}}", "fb");
    try expectRender(ctx, "{{env.NOPE | default(\"double\")}}", "double");
    try expectRender(ctx, "{{env.NOPE | default()}}", "");
    // Цепочка фильтров применяется слева направо.
    try expectRender(ctx, "{{profile | upper | lower}}", "dev");
    try expectRender(ctx, "{{env.NOPE | default('mixed') | upper}}", "MIXED");
}

test "quote filter wraps in single quotes and escapes them" {
    try expectRender(.{ .config_root = "/a b" }, "{{config_root | quote}}", "'/a b'");
    try expectRender(.{ .config_root = "it's" }, "{{config_root | quote}}", "'it'\\''s'");
}

test "dirname and basename follow Go's filepath" {
    const cases = [_]struct { in: []const u8, dir: []const u8, base: []const u8 }{
        .{ .in = "/a/b/c", .dir = "/a/b", .base = "c" },
        .{ .in = "/a/b/c/", .dir = "/a/b/c", .base = "c" },
        .{ .in = "c", .dir = ".", .base = "c" },
        .{ .in = "/", .dir = "/", .base = "/" },
        .{ .in = "", .dir = ".", .base = "." },
        .{ .in = "/a", .dir = "/", .base = "a" },
        .{ .in = "a/b", .dir = "a", .base = "b" },
        .{ .in = "/a//b", .dir = "/a", .base = "b" },
    };
    for (cases) |c| {
        const ctx: Context = .{ .config_root = c.in };
        try expectRender(ctx, "{{config_root | dirname}}", c.dir);
        try expectRender(ctx, "{{config_root | basename}}", c.base);
    }
}

test "clean matches Go filepath.Clean" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "." },
        .{ .in = "/", .want = "/" },
        .{ .in = ".", .want = "." },
        .{ .in = "a/b/../c", .want = "a/c" },
        .{ .in = "/a/b/../../c", .want = "/c" },
        .{ .in = "/a/./b//c/", .want = "/a/b/c" },
        .{ .in = "../a", .want = "../a" },
        .{ .in = "/../a", .want = "/a" },
        .{ .in = "a/..", .want = "." },
        .{ .in = "a/../..", .want = ".." },
    };
    for (cases) |c| {
        const got = try clean(testing.allocator, c.in);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("clean({s})\n", .{c.in});
            return err;
        };
    }
}

test "abspath leaves an absolute path alone and cleans it" {
    try expectRender(.{ .config_root = "/a/b/../c" }, "{{config_root | abspath}}", "/a/c");
}

test "errors" {
    var diag: Diagnostics = .{};

    try testing.expectError(
        error.UnknownVariable,
        render(testing.allocator, test_io, "{{ undefined }}", .{}, &diag),
    );
    try testing.expectEqualStrings("undefined", diag.name);

    try testing.expectError(
        error.UnterminatedTemplate,
        render(testing.allocator, test_io, "unterminated {{ var", .{}, &diag),
    );
    try testing.expectEqual(@as(usize, 13), diag.offset);

    try testing.expectError(
        error.UnknownFilter,
        render(testing.allocator, test_io, "{{profile | nosuch}}", .{ .profile = "dev" }, &diag),
    );
    try testing.expectEqualStrings("nosuch", diag.name);

    try testing.expectError(
        error.MissingClosingParen,
        render(testing.allocator, test_io, "{{profile | default('x'}}", .{ .profile = "dev" }, &diag),
    );

    // json и base64 обещаны шапкой Go-пакета, но не реализованы там — и здесь
    // тоже, чтобы поведение совпадало.
    try testing.expectError(
        error.UnknownFilter,
        render(testing.allocator, test_io, "{{profile | json}}", .{ .profile = "dev" }, &diag),
    );
    try testing.expectError(
        error.UnknownFilter,
        render(testing.allocator, test_io, "{{profile | base64}}", .{ .profile = "dev" }, &diag),
    );
}

test "extractVarRefs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const refs = try extractVarRefs(a, "{{config_root}}/logs/{{profile}}.log");
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("config_root", refs[0]);
    try testing.expectEqualStrings("profile", refs[1]);

    // Префикс env. снимается, фильтры отбрасываются.
    const with_filters = try extractVarRefs(a, "{{ env.HOME | upper }}-{{ OTHER|lower }}");
    try testing.expectEqual(@as(usize, 2), with_filters.len);
    try testing.expectEqualStrings("HOME", with_filters[0]);
    try testing.expectEqualStrings("OTHER", with_filters[1]);

    // Незакрытая скобка не ошибка: отдаём собранное.
    const partial = try extractVarRefs(a, "{{a}} and {{unclosed");
    try testing.expectEqual(@as(usize, 1), partial.len);
    try testing.expectEqualStrings("a", partial[0]);

    const none = try extractVarRefs(a, "no templates here");
    try testing.expectEqual(@as(usize, 0), none.len);
}
