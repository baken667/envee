//! Пути, по которым envee хранит своё состояние.
//!
//! Порт `internal/paths/paths.go`, где та же работа делалась библиотекой
//! `adrg/xdg`. Здесь она воспроизведена, потому что от неё нужен ровно один
//! кусок — базовые каталоги, — и потому что зависимость ради него в Zig-версии
//! не нужна.
//!
//! ВАЖНО: дефолты у macOS и Linux РАЗНЫЕ, и это не оплошность порта, а
//! поведение `adrg/xdg@v0.5.3` (paths_darwin.go), которое обязано сохраниться:
//! иначе после перехода с Go на Zig пользователь потеряет свой trust-store и
//! сохранённые секреты.
//!
//!             | XDG_* задан | macOS по умолчанию            | Linux по умолчанию
//!   config    | из него     | ~/Library/Application Support | ~/.config
//!   data      | из него     | ~/Library/Application Support | ~/.local/share
//!   cache     | из него     | ~/Library/Caches              | ~/.cache
//!   runtime   | из него     | ~/Library/Application Support | /run/user/<uid>
//!
//! См. docs/adr/0004-trust-model.md и docs/adr/0012-cross-platform.md.
//!
//! Владение: `Paths` владеет всеми своими строками; в проде живёт в арене
//! процесса.

const std = @import("std");
const perms = @import("perms.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Environ = std.process.Environ.Map;

/// Имя подкаталога приложения. Каждый путь обязан быть внутри него: без
/// этого сокет и lock-файл демона легли бы прямо в общий runtime-каталог,
/// рядом с файлами всех остальных программ.
const app = "envee";

pub const Paths = struct {
    /// Пользовательский каталог конфигурации.
    config: []const u8,
    /// Каталог данных. Trust-store живёт здесь, а НЕ в config: каталоги вроде
    /// ~/.config часто синхронизируются в облако, и одобрения конфигов
    /// разъезжались бы между машинами (ADR-0004). На macOS эти два каталога
    /// совпадают, и разделение там недоступно.
    data: []const u8,
    cache: []const u8,
    /// Каталог для сокета и lock-файла демона.
    runtime: []const u8,

    trust_store: []const u8,
    plugin_metadata_cache: []const u8,
    socket: []const u8,
    lock_file: []const u8,

    pub fn init(gpa: Allocator, environ: *const Environ) Allocator.Error!Paths {
        const home = userHomeDir(environ);

        const config = try envPath(gpa, environ, "XDG_CONFIG_HOME", home, default_config);
        errdefer gpa.free(config);
        const data = try envPath(gpa, environ, "XDG_DATA_HOME", home, default_data);
        errdefer gpa.free(data);
        const cache = try envPath(gpa, environ, "XDG_CACHE_HOME", home, default_cache);
        errdefer gpa.free(cache);
        const runtime_base = try runtimeDir(gpa, environ, home);
        defer gpa.free(runtime_base);

        const config_dir = try std.fs.path.join(gpa, &.{ config, app });
        const data_dir = try std.fs.path.join(gpa, &.{ data, app });
        const cache_dir = try std.fs.path.join(gpa, &.{ cache, app });
        const runtime_dir = try std.fs.path.join(gpa, &.{ runtime_base, app });

        gpa.free(config);
        gpa.free(data);
        gpa.free(cache);

        return .{
            .config = config_dir,
            .data = data_dir,
            .cache = cache_dir,
            .runtime = runtime_dir,
            .trust_store = try std.fs.path.join(gpa, &.{ data_dir, "trust" }),
            .plugin_metadata_cache = try std.fs.path.join(gpa, &.{ data_dir, "plugins" }),
            .socket = try std.fs.path.join(gpa, &.{ runtime_dir, "envee.sock" }),
            .lock_file = try std.fs.path.join(gpa, &.{ runtime_dir, "envee.lock" }),
        };
    }

    pub fn deinit(p: Paths, gpa: Allocator) void {
        for ([_][]const u8{
            p.config,      p.data,   p.cache,     p.runtime,
            p.trust_store, p.socket, p.lock_file, p.plugin_metadata_cache,
        }) |s| gpa.free(s);
    }

    /// Создаёт каталоги, которые envee пишет. Вызывается на каждом запуске,
    /// поэтому обязана быть идемпотентной.
    ///
    /// Runtime-каталог создаётся с правами 0700: в нём лежит сокет демона,
    /// через который можно вытянуть разрешённое окружение вместе с секретами.
    /// Если каталог уже существует, права не трогаются — ровно как у
    /// MkdirAll в Go-эталоне.
    ///
    /// На macOS runtime и data указывают на один и тот же каталог, поэтому
    /// порядок важен: data создаётся первым и остаётся с обычными правами.
    pub fn ensureDirs(p: Paths, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        for ([_][]const u8{
            p.config,
            p.data,
            p.cache,
            p.trust_store,
            p.plugin_metadata_cache,
        }) |dir| {
            _ = try cwd.createDirPathStatus(io, dir, .default_dir);
        }
        _ = try cwd.createDirPathStatus(io, p.runtime, perms.fromMode(0o700));
    }
};

// ---- базовые каталоги ------------------------------------------------------

const macos = builtin.os.tag == .macos;
const windows = builtin.os.tag == .windows;

/// Как строится путь по умолчанию, если переменная XDG_* не задана.
const Default = struct {
    /// Компоненты, дописываемые к домашнему каталогу.
    parts: []const []const u8,
};

const default_config: Default = if (macos)
    .{ .parts = &.{ "Library", "Application Support" } }
else if (windows)
    .{ .parts = &.{ "AppData", "Local" } }
else
    .{ .parts = &.{".config"} };

const default_data: Default = if (macos)
    .{ .parts = &.{ "Library", "Application Support" } }
else if (windows)
    .{ .parts = &.{ "AppData", "Local" } }
else
    .{ .parts = &.{ ".local", "share" } };

const default_cache: Default = if (macos)
    .{ .parts = &.{ "Library", "Caches" } }
else if (windows)
    .{ .parts = &.{ "AppData", "Local", "cache" } }
else
    .{ .parts = &.{".cache"} };

/// Домашний каталог. Пустой $HOME даёт "/" — так же поступает adrg/xdg.
fn userHomeDir(environ: *const Environ) []const u8 {
    const home = environ.get(if (windows) "USERPROFILE" else "HOME") orelse "";
    return if (home.len > 0) home else "/";
}

/// Читает переменную XDG_*; если она пуста или задаёт ОТНОСИТЕЛЬНЫЙ путь —
/// берёт значение по умолчанию.
///
/// Проверка на абсолютность существенна. Именно из-за её отсутствия
/// Go-версия однажды брала относительный путь "envee" и читала каталог
/// ./envee в текущей директории вместо каталога в домашнем.
fn envPath(
    gpa: Allocator,
    environ: *const Environ,
    name: []const u8,
    home: []const u8,
    default: Default,
) Allocator.Error![]u8 {
    if (environ.get(name)) |raw| {
        const expanded = try expandHome(gpa, raw, home);
        if (expanded.len > 0 and std.fs.path.isAbsolute(expanded)) return expanded;
        gpa.free(expanded);
    }
    var buf: [8][]const u8 = undefined;
    buf[0] = home;
    for (default.parts, 1..) |part, i| buf[i] = part;
    return std.fs.path.join(gpa, buf[0 .. default.parts.len + 1]);
}

/// Runtime-каталог. На Linux по умолчанию /run/user/<uid>, на остальных
/// платформах совпадает с каталогом данных.
fn runtimeDir(gpa: Allocator, environ: *const Environ, home: []const u8) Allocator.Error![]u8 {
    if (environ.get("XDG_RUNTIME_DIR")) |raw| {
        const expanded = try expandHome(gpa, raw, home);
        if (expanded.len > 0 and std.fs.path.isAbsolute(expanded)) return expanded;
        gpa.free(expanded);
    }
    if (macos or windows) {
        var buf: [8][]const u8 = undefined;
        buf[0] = home;
        for (default_data.parts, 1..) |part, i| buf[i] = part;
        return std.fs.path.join(gpa, buf[0 .. default_data.parts.len + 1]);
    }
    // В std 0.16 нет `posix.getuid`; на Linux это прямой системный вызов,
    // на остальных POSIX — libc.
    const uid: u64 = if (builtin.os.tag == .linux) std.os.linux.getuid() else std.c.getuid();
    return std.fmt.allocPrint(gpa, "/run/user/{d}", .{uid});
}

/// Подставляет домашний каталог вместо ведущих `~` и `$HOME`.
fn expandHome(gpa: Allocator, path: []const u8, home: []const u8) Allocator.Error![]u8 {
    if (path.len == 0 or home.len == 0) return gpa.dupe(u8, path);
    if (path[0] == '~') return std.fs.path.join(gpa, &.{ home, path[1..] });
    if (std.mem.startsWith(u8, path, "$HOME")) return std.fs.path.join(gpa, &.{ home, path[5..] });
    return gpa.dupe(u8, path);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Собирает окружение из пар для теста.
fn testEnviron(gpa: Allocator, pairs: []const [2][]const u8) !Environ {
    var m: Environ = .init(gpa);
    for (pairs) |p| try m.put(p[0], p[1]);
    return m;
}

test "every path is absolute and scoped to an envee directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{.{ "HOME", "/home/alice" }});
    const p = try Paths.init(a, &environ);

    const all = [_][]const u8{
        p.config,      p.data,   p.cache,     p.runtime,
        p.trust_store, p.socket, p.lock_file, p.plugin_metadata_cache,
    };
    for (all) |path| {
        try testing.expect(path.len > 0);
        // Относительный путь означал бы, что envee читает каталог рядом с
        // текущим рабочим, а не в домашнем.
        try testing.expect(std.fs.path.isAbsolute(path));
        // Без подкаталога приложения сокет и lock-файл легли бы в общий
        // runtime-каталог рядом с чужими файлами.
        try testing.expect(std.mem.indexOf(u8, path, "/envee") != null);
    }
}

test "derived paths nest under their parents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{.{ "HOME", "/home/alice" }});
    const p = try Paths.init(a, &environ);

    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ p.data, "trust" }), p.trust_store);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ p.data, "plugins" }), p.plugin_metadata_cache);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ p.runtime, "envee.sock" }), p.socket);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ p.runtime, "envee.lock" }), p.lock_file);
}

test "XDG variables win when they are absolute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{
        .{ "HOME", "/home/alice" },
        .{ "XDG_CONFIG_HOME", "/custom/config" },
        .{ "XDG_DATA_HOME", "/custom/data" },
        .{ "XDG_CACHE_HOME", "/custom/cache" },
        .{ "XDG_RUNTIME_DIR", "/custom/run" },
    });
    const p = try Paths.init(a, &environ);

    try testing.expectEqualStrings("/custom/config/envee", p.config);
    try testing.expectEqualStrings("/custom/data/envee", p.data);
    try testing.expectEqualStrings("/custom/cache/envee", p.cache);
    try testing.expectEqualStrings("/custom/run/envee", p.runtime);
    try testing.expectEqualStrings("/custom/data/envee/trust", p.trust_store);
}

// Относительное значение XDG_* игнорируется и уступает умолчанию. Ровно на
// этом Go-версия однажды и погорела: она брала $XDG_CONFIG_HOME напрямую и
// при незаданной переменной получала относительный путь "envee", то есть
// читала ./envee из текущего каталога.
test "a relative XDG variable is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{
        .{ "HOME", "/home/alice" },
        .{ "XDG_CONFIG_HOME", "relative/path" },
        .{ "XDG_DATA_HOME", "" },
    });
    const p = try Paths.init(a, &environ);

    try testing.expect(std.mem.indexOf(u8, p.config, "relative/path") == null);
    try testing.expect(std.fs.path.isAbsolute(p.config));
    try testing.expect(std.fs.path.isAbsolute(p.data));
}

test "tilde and $HOME are expanded in XDG variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{
        .{ "HOME", "/home/alice" },
        .{ "XDG_CONFIG_HOME", "~/cfg" },
        .{ "XDG_DATA_HOME", "$HOME/dat" },
    });
    const p = try Paths.init(a, &environ);

    try testing.expectEqualStrings("/home/alice/cfg/envee", p.config);
    try testing.expectEqualStrings("/home/alice/dat/envee", p.data);
}

// Дефолты обязаны совпасть с adrg/xdg@v0.5.3, иначе при переходе с Go на Zig
// пользователь теряет trust-store и сохранённые секреты.
test "platform defaults match adrg/xdg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{.{ "HOME", "/home/alice" }});
    const p = try Paths.init(a, &environ);

    if (macos) {
        try testing.expectEqualStrings("/home/alice/Library/Application Support/envee", p.config);
        try testing.expectEqualStrings("/home/alice/Library/Application Support/envee", p.data);
        try testing.expectEqualStrings("/home/alice/Library/Caches/envee", p.cache);
        try testing.expectEqualStrings("/home/alice/Library/Application Support/envee", p.runtime);
    } else if (!windows) {
        try testing.expectEqualStrings("/home/alice/.config/envee", p.config);
        try testing.expectEqualStrings("/home/alice/.local/share/envee", p.data);
        try testing.expectEqualStrings("/home/alice/.cache/envee", p.cache);
        // runtime по умолчанию — /run/user/<uid>, uid зависит от машины.
        try testing.expect(std.mem.startsWith(u8, p.runtime, "/run/user/"));
    }
}

test "an empty HOME falls back to the root directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try testEnviron(a, &.{});
    const p = try Paths.init(a, &environ);
    try testing.expect(std.fs.path.isAbsolute(p.config));
    try testing.expect(std.mem.startsWith(u8, p.config, "/"));
}

test "ensureDirs creates everything, and does not fail twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const cwd_path = try std.process.currentPathAlloc(io, a);
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
    const root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &name });
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var environ = try testEnviron(a, &.{
        .{ "HOME", root },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "cfg" }) },
        .{ "XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "dat" }) },
        .{ "XDG_CACHE_HOME", try std.fs.path.join(a, &.{ root, "cch" }) },
        .{ "XDG_RUNTIME_DIR", try std.fs.path.join(a, &.{ root, "run" }) },
    });
    const p = try Paths.init(a, &environ);

    try p.ensureDirs(io);
    // Повторный вызов обязан быть безобидным: он делается на каждом запуске.
    try p.ensureDirs(io);

    for ([_][]const u8{ p.config, p.data, p.cache, p.runtime, p.trust_store, p.plugin_metadata_cache }) |dir| {
        const st = try std.Io.Dir.cwd().statFile(io, dir, .{});
        try testing.expectEqual(std.Io.File.Kind.directory, st.kind);
    }

    // Сокет демона отдаёт разрешённое окружение вместе с секретами, поэтому
    // его каталог не должен быть доступен другим пользователям. В этом тесте
    // XDG_RUNTIME_DIR отделён от data, так что каталог создаётся с нуля.
    const runtime_stat = try std.Io.Dir.cwd().statFile(io, p.runtime, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), runtime_stat.permissions.toMode() & 0o777);
}
