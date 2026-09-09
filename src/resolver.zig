//! Поиск и слияние файлов `envee.toml` по дереву каталогов.
//!
//! Порядок обнаружения, от высшего приоритета к низшему (ADR-0003):
//!   1. `envee.local.<profile>.toml`   — личное, для конкретного профиля
//!   2. `envee.<profile>.toml`         — общее, для конкретного профиля
//!   3. `envee.local.toml`             — личное, должно быть в .gitignore
//!   4. `envee.toml`                   — конфиг проекта
//!   5. `envee.d/*.toml`               — фрагменты, по алфавиту
//!   6. то же самое в каждом родительском каталоге, снизу вверх
//!   7. `<config_dir>/config.toml`     — глобальные значения по умолчанию
//!
//! ВНИМАНИЕ, отличие от Go-версии по ПОВЕДЕНИЮ. Go обходил этот список в том
//! же порядке, но сливал так, что каждый следующий файл ПЕРЕЗАПИСЫВАЛ
//! предыдущий. В результате приоритет оказывался вывернут наизнанку:
//! `envee.d/*.toml` побеждал `envee.toml`, а конфиг родительского каталога —
//! конфиг дочернего. Последнее ломало ровно тот сценарий монорепозитория,
//! который рекламируют README и `examples/monorepo/` («дочерний envee.toml
//! имеет приоритет над этим»). Здесь побеждает файл с БОЛЬШИМ приоритетом,
//! как и написано в документации.
//!
//! Списочные директивы (`_.path`, `_.file`, …) при этом склеиваются в
//! порядке обнаружения: первым идёт вклад файла с высшим приоритетом. Для
//! `_.path` это существенно — его элементы попадают в начало $PATH в том же
//! порядке, то есть первыми ищутся каталоги самого близкого конфига.
//!
//! Владение: всё выделяется из переданной арены, как и в config.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const value = @import("toml/value.zig");
const paths_mod = @import("paths.zig");

pub const Config = config.Config;

pub const Error = error{
    /// Ни одного `envee.toml` не нашлось.
    NoConfigFound,
} || config.Error || std.Io.Dir.ReadFileAllocError || std.Io.Dir.OpenError;

pub const Diagnostics = struct {
    /// Файл, на котором споткнулись.
    path: []const u8 = "",
    /// Каталог, из которого шёл поиск (для NoConfigFound).
    searched_from: []const u8 = "",
    parse: config.Diagnostics = .{},
};

pub const Resolver = struct {
    cwd: []const u8,
    /// Каталог глобального конфига. Обязан быть АБСОЛЮТНЫМ: относительный
    /// путь заставил бы читать каталог рядом с текущим рабочим.
    config_dir: []const u8,
    /// Активный профиль; пустая строка — файлы профиля не ищутся.
    profile: []const u8 = "",
    /// Верхняя граница подъёма, обычно корень репозитория.
    stop_at_root: []const u8 = "",

    pub fn init(cwd: []const u8, p: paths_mod.Paths) Resolver {
        return .{ .cwd = cwd, .config_dir = p.config };
    }

    /// Пути всех существующих файлов конфигурации, от высшего приоритета к
    /// низшему. Несуществующие не возвращаются.
    pub fn discover(r: Resolver, arena: Allocator, io: std.Io) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer seen.deinit(arena);

        const cwd_dir = std.Io.Dir.cwd();
        const add = struct {
            fn f(
                a: Allocator,
                dir: std.Io.Dir,
                the_io: std.Io,
                list: *std.ArrayList([]const u8),
                known: *std.StringArrayHashMapUnmanaged(void),
                path: []const u8,
            ) !void {
                if (known.contains(path)) return;
                try known.put(a, path, {});
                _ = dir.statFile(the_io, path, .{}) catch return;
                try list.append(a, path);
            }
        }.f;

        var dir = r.cwd;
        while (true) {
            if (r.profile.len > 0) {
                try add(arena, cwd_dir, io, &out, &seen, try join(arena, dir, "envee.local.", r.profile, ".toml"));
                try add(arena, cwd_dir, io, &out, &seen, try join(arena, dir, "envee.", r.profile, ".toml"));
            }
            try add(arena, cwd_dir, io, &out, &seen, try std.fs.path.join(arena, &.{ dir, "envee.local.toml" }));
            try add(arena, cwd_dir, io, &out, &seen, try std.fs.path.join(arena, &.{ dir, "envee.toml" }));

            for (try fragmentsIn(arena, io, dir)) |frag| {
                try add(arena, cwd_dir, io, &out, &seen, frag);
            }

            // Подъём прекращается на корне файловой системы либо на явно
            // заданной границе. Шаг ровно один за итерацию: в Go здесь
            // однажды оказалось два, и конфиг непосредственного родителя
            // не находился вовсе.
            if (isFsRoot(dir)) break;
            if (r.stop_at_root.len > 0 and std.mem.eql(u8, dir, r.stop_at_root)) break;
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            dir = parent;
        }

        if (r.config_dir.len > 0) {
            try add(arena, cwd_dir, io, &out, &seen, try std.fs.path.join(arena, &.{ r.config_dir, "config.toml" }));
        }
        return out.toOwnedSlice(arena);
    }

    /// Находит, разбирает и сливает все конфиги в один.
    pub fn loadAll(r: Resolver, arena: Allocator, io: std.Io, diag: ?*Diagnostics) Error!Config {
        const files = try r.discover(arena, io);
        if (files.len == 0) {
            if (diag) |d| d.searched_from = r.cwd;
            return error.NoConfigFound;
        }

        var loaded: std.ArrayList(Config) = .empty;
        var sources: std.ArrayList(config.SourceFile) = .empty;

        for (files) |f| {
            var parse_diag: config.Diagnostics = .{};
            const c = config.parseFile(arena, io, f, &parse_diag) catch |err| {
                if (diag) |d| d.* = .{ .path = f, .parse = parse_diag };
                return @errorCast(err);
            };
            try loaded.append(arena, c);
            try sources.appendSlice(arena, c.sources);
            // Файл может запретить подниматься выше: всё, что ниже него по
            // приоритету, в слияние не попадает.
            if (c.stop_search_up) break;
        }

        var merged: Config = .{ .env = try value.Table.create(arena) };
        // Обход идёт от высшего приоритета к низшему, и побеждает тот, кто
        // пришёл ПЕРВЫМ. Файлы низкого приоритета лишь заполняют пробелы.
        for (loaded.items) |c| try mergeInto(arena, &merged, c);

        // Путь и хеш описывают первый файл; остальные — в sources, и именно
        // по ним обязана идти проверка доверия, иначе одобрен будет один
        // файл, а применены все.
        merged.path = loaded.items[0].path;
        merged.file_hash = loaded.items[0].file_hash;
        merged.mod_time = loaded.items[0].mod_time;
        merged.sources = try sources.toOwnedSlice(arena);
        return merged;
    }
};

/// Сливает `src` в `dst`, где УЖЕ ЗАПИСАННОЕ в dst сильнее.
///
/// Обратное направление относительно Go: там побеждал последний слитый, из-за
/// чего приоритет выворачивался. См. шапку файла.
fn mergeInto(arena: Allocator, dst: *Config, src: Config) Allocator.Error!void {
    if (dst.schema.len == 0 or std.mem.eql(u8, dst.schema, config.schema_version)) {
        if (src.schema.len > 0) dst.schema = src.schema;
    }
    if (dst.profile.len == 0) dst.profile = src.profile;
    // Флаги складываются по «или»: любой файл вправе их включить.
    dst.stop_search_up = dst.stop_search_up or src.stop_search_up;
    dst.profile_from_branch = dst.profile_from_branch or src.profile_from_branch;

    for (src.env.keys(), src.env.map.values()) |k, v| {
        if (dst.env.get(k) != null) continue;
        try dst.env.put(arena, k, v);
    }

    dst.profiles = try mergeProfiles(arena, dst.profiles, src.profiles);
    dst.directives = try mergeDirectives(arena, dst.directives, src.directives);
    dst.watched_paths = try concat(arena, []const u8, dst.watched_paths, src.watched_paths);
}

fn mergeProfiles(
    arena: Allocator,
    dst: []config.Profile,
    src: []config.Profile,
) Allocator.Error![]config.Profile {
    var out: std.ArrayList(config.Profile) = .empty;
    try out.appendSlice(arena, dst);

    outer: for (src) |sp| {
        for (out.items) |*dp| {
            if (!std.mem.eql(u8, dp.name, sp.name)) continue;
            // Профиль с таким именем уже есть: переменные высшего приоритета
            // остаются, недостающие добираются отсюда.
            for (sp.env.keys(), sp.env.map.values()) |k, v| {
                if (dp.env.get(k) != null) continue;
                try dp.env.put(arena, k, v);
            }
            dp.extends = try concat(arena, []const u8, dp.extends, sp.extends);
            dp.required = try concat(arena, []const u8, dp.required, sp.required);
            dp.directives = try mergeDirectives(arena, dp.directives, sp.directives);
            continue :outer;
        }
        try out.append(arena, sp);
    }
    return out.toOwnedSlice(arena);
}

/// Списки директив склеиваются, порядок обнаружения сохраняется.
///
/// Для `_.path` порядок значим: его элементы уходят в начало $PATH в том же
/// порядке, поэтому первым обязан идти вклад ближайшего конфига.
fn mergeDirectives(
    arena: Allocator,
    dst: config.Directives,
    src: config.Directives,
) Allocator.Error!config.Directives {
    var out = dst;
    out.file = try concat(arena, config.FileRef, dst.file, src.file);
    out.path = try concat(arena, config.PathEntry, dst.path, src.path);
    out.script = try concat(arena, config.ScriptRef, dst.script, src.script);
    out.source = try concat(arena, config.SourceRef, dst.source, src.source);

    // Секрет с уже занятым именем не перекрывается: побеждает объявление из
    // файла с высшим приоритетом.
    var secrets: std.ArrayList(config.NamedSecret) = .empty;
    try secrets.appendSlice(arena, dst.secret);
    for (src.secret) |s| {
        var taken = false;
        for (secrets.items) |existing| {
            if (std.mem.eql(u8, existing.name, s.name)) taken = true;
        }
        if (!taken) try secrets.append(arena, s);
    }
    out.secret = try secrets.toOwnedSlice(arena);
    return out;
}

fn concat(arena: Allocator, comptime T: type, a: []const T, b: []const T) Allocator.Error![]const T {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out = try arena.alloc(T, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Файлы `envee.d/*.toml` одного каталога, по алфавиту. Скрытые пропускаются.
fn fragmentsIn(arena: Allocator, io: std.Io, dir: []const u8) Error![]const []const u8 {
    const frag_dir_path = try std.fs.path.join(arena, &.{ dir, "envee.d" });
    var frag_dir = std.Io.Dir.cwd().openDir(io, frag_dir_path, .{ .iterate = true }) catch return &.{};
    defer frag_dir.close(io);

    var out: std.ArrayList([]const u8) = .empty;
    var it = frag_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ frag_dir_path, entry.name }));
    }
    const items = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, @constCast(items), {}, lessThanSlice);
    return items;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn join(arena: Allocator, dir: []const u8, a: []const u8, b: []const u8, c: []const u8) Allocator.Error![]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ a, b, c });
    return std.fs.path.join(arena, &.{ dir, name });
}

fn isFsRoot(dir: []const u8) bool {
    return dir.len == 1 and dir[0] == std.fs.path.sep;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Временный каталог с известным абсолютным путём: пути нужны resolver'у.
const TempDir = struct {
    path: []const u8,

    fn create(gpa: Allocator) !TempDir {
        const io = std.testing.io;
        const cwd_path = try std.process.currentPathAlloc(io, gpa);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const path = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .path = path };
    }

    fn destroy(t: TempDir) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, t.path) catch {};
    }

    fn write(t: TempDir, gpa: Allocator, sub: []const u8, body: []const u8) ![]const u8 {
        const io = std.testing.io;
        const full = try std.fs.path.join(gpa, &.{ t.path, sub });
        if (std.fs.path.dirname(full)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full, .data = body });
        return full;
    }
};

fn resolverAt(cwd: []const u8, stop_at: []const u8) Resolver {
    return .{ .cwd = cwd, .config_dir = "", .stop_at_root = stop_at };
}

fn contains(list: []const []const u8, want: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, want)) return true;
    }
    return false;
}

// Подъём обязан посетить КАЖДЫЙ каталог-предок. В Go здесь однажды
// оказалось два шага за итерацию, и конфиг непосредственного родителя не
// находился — а это ровно раскладка монорепозитория из README.
test "discover visits every ancestor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var expected: [4][]const u8 = undefined;
    for ([_][]const u8{ "envee.toml", "a/envee.toml", "a/b/envee.toml", "a/b/c/envee.toml" }, 0..) |sub, i| {
        expected[i] = try tmp.write(a, sub, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");
    }

    const deep = try std.fs.path.join(a, &.{ tmp.path, "a", "b", "c" });
    const files = try resolverAt(deep, tmp.path).discover(a, std.testing.io);

    for (expected) |want| {
        testing.expect(contains(files, want)) catch {
            std.debug.print("discover skipped {s}\n", .{want});
            return error.TestExpectedEqual;
        };
    }
}

test "discover returns files in priority order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const base = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n");
    const local = try tmp.write(a, "envee.local.toml", "schema = \"envee/v1\"\n");
    const frag_a = try tmp.write(a, "envee.d/10-a.toml", "schema = \"envee/v1\"\n");
    const frag_b = try tmp.write(a, "envee.d/20-b.toml", "schema = \"envee/v1\"\n");
    _ = try tmp.write(a, "envee.d/.hidden.toml", "schema = \"envee/v1\"\n");
    _ = try tmp.write(a, "envee.d/notes.txt", "ignored");

    const files = try resolverAt(tmp.path, tmp.path).discover(a, std.testing.io);
    try testing.expectEqual(@as(usize, 4), files.len);
    try testing.expectEqualStrings(local, files[0]);
    try testing.expectEqualStrings(base, files[1]);
    // Фрагменты — по алфавиту.
    try testing.expectEqualStrings(frag_a, files[2]);
    try testing.expectEqualStrings(frag_b, files[3]);
}

test "profile-specific files come first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n");
    const prod = try tmp.write(a, "envee.prod.toml", "schema = \"envee/v1\"\n");
    const local_prod = try tmp.write(a, "envee.local.prod.toml", "schema = \"envee/v1\"\n");

    var r = resolverAt(tmp.path, tmp.path);
    r.profile = "prod";
    const files = try r.discover(a, std.testing.io);
    try testing.expectEqualStrings(local_prod, files[0]);
    try testing.expectEqualStrings(prod, files[1]);

    // Без активного профиля эти файлы не подхватываются.
    const without_profile = try resolverAt(tmp.path, tmp.path).discover(a, std.testing.io);
    try testing.expectEqual(@as(usize, 1), without_profile.len);
}

test "loadAll records every contributing file as a source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const base = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");
    const local = try tmp.write(a, "envee.local.toml", "schema = \"envee/v1\"\n[env]\nB = \"2\"\n");
    const frag = try tmp.write(a, "envee.d/10-c.toml", "schema = \"envee/v1\"\n[env]\nC = \"3\"\n");

    const c = try resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, null);

    // Проверку доверия обходит именно этот список: запиши сюда только первый
    // файл — и остальные применились бы, ни разу не будучи одобренными.
    try testing.expectEqual(@as(usize, 3), c.sources.len);
    for ([_][]const u8{ base, local, frag }) |want| {
        var found = false;
        for (c.sources) |s| {
            if (std.mem.eql(u8, s.path, want)) {
                found = true;
                try testing.expect(std.mem.startsWith(u8, s.hash, "sha256:"));
            }
        }
        testing.expect(found) catch {
            std.debug.print("sources is missing {s}\n", .{want});
            return error.TestExpectedEqual;
        };
    }

    // Слияние при этом работает: переменные из всех файлов на месте.
    for ([_][]const u8{ "A", "B", "C" }) |k| try testing.expect(c.env.get(k) != null);
}

// Главное свойство слияния, и ровно то, что в Go было вывернуто наизнанку.
test "the higher-priority file wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nWHO = \"base\"\nONLY_BASE = \"b\"\n");
    _ = try tmp.write(a, "envee.local.toml", "schema = \"envee/v1\"\n[env]\nWHO = \"local\"\n");
    _ = try tmp.write(a, "envee.d/10-a.toml", "schema = \"envee/v1\"\n[env]\nWHO = \"fragment\"\n");

    const c = try resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, null);
    // Личный конфиг — высший приоритет, фрагменты — низший.
    try testing.expectEqualStrings("local", c.env.get("WHO").?.asString().?);
    // Значения, которых нет выше, добираются снизу.
    try testing.expectEqualStrings("b", c.env.get("ONLY_BASE").?.asString().?);
}

// Раскладка монорепозитория: дочерний конфиг обязан перебивать корневой.
// Так написано и в README, и в комментарии самого examples/monorepo.
test "a child config wins over its parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nWHO = \"monorepo-root\"\nSHARED = \"yes\"\n");
    _ = try tmp.write(a, "services/api/envee.toml", "schema = \"envee/v1\"\n[env]\nWHO = \"service-api\"\n");

    const child = try std.fs.path.join(a, &.{ tmp.path, "services", "api" });
    const c = try resolverAt(child, tmp.path).loadAll(a, std.testing.io, null);

    try testing.expectEqualStrings("service-api", c.env.get("WHO").?.asString().?);
    // Общие значения корня при этом наследуются.
    try testing.expectEqualStrings("yes", c.env.get("SHARED").?.asString().?);
}

test "stop_search_up cuts off everything below it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nFROM_ROOT = \"yes\"\n");
    _ = try tmp.write(a, "child/envee.toml", "schema = \"envee/v1\"\nstop_search_up = true\n[env]\nA = \"1\"\n");

    const child = try std.fs.path.join(a, &.{ tmp.path, "child" });
    const c = try resolverAt(child, tmp.path).loadAll(a, std.testing.io, null);

    try testing.expect(c.stop_search_up);
    try testing.expect(c.env.get("A") != null);
    try testing.expect(c.env.get("FROM_ROOT") == null);
    try testing.expectEqual(@as(usize, 1), c.sources.len);
}

test "directives are concatenated in discovery order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\n[env]\n_.path = [\"./from-base\"]\n");
    _ = try tmp.write(a, "envee.local.toml", "schema = \"envee/v1\"\n[env]\n_.path = [\"./from-local\"]\n");

    const c = try resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, null);
    try testing.expectEqual(@as(usize, 2), c.directives.path.len);
    // Элементы _.path уходят в начало $PATH в этом же порядке, поэтому
    // первым обязан идти вклад файла с высшим приоритетом.
    try testing.expectEqualStrings("./from-local", c.directives.path[0].path);
    try testing.expectEqualStrings("./from-base", c.directives.path[1].path);
}

test "profiles merge across files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    _ = try tmp.write(a, "envee.toml",
        \\schema = "envee/v1"
        \\[profiles.dev.env]
        \\A = "base-a"
        \\B = "base-b"
        \\[profiles.prod.env]
        \\P = "1"
    );
    _ = try tmp.write(a, "envee.local.toml",
        \\schema = "envee/v1"
        \\[profiles.dev.env]
        \\A = "local-a"
        \\C = "local-c"
    );

    const c = try resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, null);
    const dev = c.profileByName("dev").?;
    try testing.expectEqualStrings("local-a", dev.env.get("A").?.asString().?);
    try testing.expectEqualStrings("base-b", dev.env.get("B").?.asString().?);
    try testing.expectEqualStrings("local-c", dev.env.get("C").?.asString().?);
    // Профиль, объявленный только в одном файле, тоже на месте.
    try testing.expect(c.profileByName("prod") != null);
}

test "no config at all is an error naming the directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var diag: Diagnostics = .{};
    try testing.expectError(
        error.NoConfigFound,
        resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, &diag),
    );
    try testing.expectEqualStrings(tmp.path, diag.searched_from);
}

test "a broken config names the file that broke" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const bad = try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\nthis is not = valid = =\n");

    var diag: Diagnostics = .{};
    try testing.expectError(
        error.UnexpectedToken,
        resolverAt(tmp.path, tmp.path).loadAll(a, std.testing.io, &diag),
    );
    try testing.expectEqualStrings(bad, diag.path);
    try testing.expectEqual(@as(usize, 2), diag.parse.line);
}

test "the global config directory is absolute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: std.process.Environ.Map = .init(a);
    try environ.put("HOME", "/home/alice");
    const p = try paths_mod.Paths.init(a, &environ);
    const r = Resolver.init("/tmp/somewhere", p);

    // Относительный путь заставил бы читать каталог ./envee рядом с текущим
    // рабочим вместо настоящего глобального конфига.
    try testing.expect(std.fs.path.isAbsolute(r.config_dir));
    try testing.expect(std.mem.endsWith(u8, r.config_dir, "envee"));
}
