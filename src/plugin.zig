//! Плагины секретов: поиск бинарей `envee-plugin-*`, протокол обмена и
//! диспетчер, который подставляется в `directive.apply`.
//!
//! Порт `internal/plugin` (exec.go, registry.go, dispatcher.go). Плагин —
//! внешний исполняемый файл; envee говорит с ним JSON'ом через stdin/stdout
//! (ADR-0007). Здесь два вызова: `<bin> metadata` при обнаружении и
//! `<bin> resolve` на каждый секрет.
//!
//! Владение: всё выделяется из арены вызывающего.

const std = @import("std");
const perms = @import("perms.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Environ = std.process.Environ.Map;

const config = @import("config.zig");
const directive = @import("directive.zig");
const gopath = @import("path.zig");

pub const prefix = "envee-plugin-";
pub const api_version = 1;
/// Таймауты те же, что в Go: metadata — 5 с, resolve — 10 с. Плагин, который
/// не отвечает, не должен подвешивать hook оболочки навсегда.
pub const metadata_timeout_ms = 5_000;
pub const resolve_timeout_ms = 10_000;

pub const Error = error{
    /// Плагин завершился с ошибкой или ответил `status != ok`.
    PluginFailed,
    /// Плагин не уложился в таймаут и был убит.
    PluginTimeout,
    /// Ответ плагина — не тот JSON, что ожидался.
    BadResponse,
    /// Для источника нет зарегистрированного плагина.
    PluginNotFound,
} || Allocator.Error;

/// Имя бинаря для источника: `op` → `envee-plugin-op`. Уже полное имя не
/// дополняется второй раз.
pub fn exeName(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, source, prefix)) return source;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, source });
}

/// `/path/to/envee-plugin-foo` → `foo`; без префикса или с пустым
/// хвостом — null.
pub fn pluginName(path: []const u8) ?[]const u8 {
    var base = std.fs.path.basename(path);
    if (builtin.os.tag == .windows) {
        const ext = std.fs.path.extension(base);
        base = base[0 .. base.len - ext.len];
    }
    if (!std.mem.startsWith(u8, base, prefix) or base.len <= prefix.len) return null;
    return base[prefix.len..];
}

/// Исполняемость файла. Windows не знает бита исполнения и решает по
/// расширению из %PATHEXT%; там достаточно самого факта, что файл есть.
fn isExecutable(io: Io, dir: Io.Dir, name: []const u8) bool {
    const st = dir.statFile(io, name, .{}) catch return false;
    if (st.kind == .directory) return false;
    if (comptime Io.File.Permissions.has_executable_bit) {
        return (st.permissions.toMode() & 0o111) != 0;
    }
    return true;
}

/// Все исполняемые `envee-plugin-*` в каталогах `path_var`, в порядке
/// обхода PATH. Ничего не запускает — только смотрит на файлы.
pub fn discoverPaths(arena: Allocator, io: Io, path_var: []const u8) Allocator.Error![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var dirs = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory) continue;
            if (!std.mem.startsWith(u8, e.name, prefix)) continue;
            if (!isExecutable(io, dir, e.name)) continue;
            try found.append(arena, try gopath.join(arena, &.{ dir_path, e.name }));
        }
    }
    return found.toOwnedSlice(arena);
}

/// Первый исполняемый `exe` в PATH — аналог `exec.LookPath`.
pub fn lookPath(arena: Allocator, io: Io, path_var: []const u8, exe: []const u8) Allocator.Error!?[]const u8 {
    var dirs = std.mem.splitScalar(u8, path_var, std.fs.path.delimiter);
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch continue;
        defer dir.close(io);
        if (isExecutable(io, dir, exe)) return try gopath.join(arena, &.{ dir_path, exe });
    }
    return null;
}

// ---- протокол ----------------------------------------------------------------

/// Ответ на `<bin> metadata`. Поля — как в JSON, чтобы разбирать напрямую.
pub const Metadata = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    api_version: i64 = 0,
    description: []const u8 = "",
    /// Списки необязательные, а не пустые по умолчанию: Go пишет пустой
    /// срез как `null`, и `plugin list --json` обязан показать то же, что
    /// прислал плагин.
    capabilities: ?[]const []const u8 = null,
    permissions: Permissions = .{},

    pub const Permissions = struct {
        network: bool = false,
        filesystem: ?[]const []const u8 = null,
        exec: ?[]const []const u8 = null,
    };
};

/// Метаданные как JSON в форме Go (`encoding/json` для `plugin.Metadata`):
/// порядок полей структуры, `null` для отсутствующих списков.
pub fn writeMetadataJson(w: *Writer, md: Metadata, indent: usize) Writer.Error!void {
    const pad = "                                ";
    const in1 = pad[0..@min(pad.len, indent + 2)];
    const in2 = pad[0..@min(pad.len, indent + 4)];
    const in0 = pad[0..@min(pad.len, indent)];
    try w.writeAll("{\n");
    try w.print("{s}\"name\": ", .{in1});
    try std.json.Stringify.value(md.name, .{}, w);
    try w.print(",\n{s}\"version\": ", .{in1});
    try std.json.Stringify.value(md.version, .{}, w);
    try w.print(",\n{s}\"api_version\": {d}", .{ in1, md.api_version });
    try w.print(",\n{s}\"description\": ", .{in1});
    try std.json.Stringify.value(md.description, .{}, w);
    try w.print(",\n{s}\"capabilities\": ", .{in1});
    try writeStringList(w, md.capabilities, indent + 2);
    try w.print(",\n{s}\"permissions\": {{\n{s}\"network\": {}", .{ in1, in2, md.permissions.network });
    try w.print(",\n{s}\"filesystem\": ", .{in2});
    try writeStringList(w, md.permissions.filesystem, indent + 4);
    try w.print(",\n{s}\"exec\": ", .{in2});
    try writeStringList(w, md.permissions.exec, indent + 4);
    try w.print("\n{s}}}\n{s}}}", .{ in1, in0 });
}

fn writeStringList(w: *Writer, list: ?[]const []const u8, indent: usize) Writer.Error!void {
    const items = list orelse return w.writeAll("null");
    if (items.len == 0) return w.writeAll("[]");
    const pad = "                                ";
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\n{s}", .{pad[0..@min(pad.len, indent + 2)]});
        try std.json.Stringify.value(item, .{}, w);
    }
    try w.print("\n{s}]", .{pad[0..@min(pad.len, indent)]});
}

/// Разбор метаданных. Списки — `?[]const u8`, и это не случайно: Go
/// сериализует пустой срез как `null` (`"exec":null` у настоящего
/// `envee-plugin-env`), а `std.json` не кладёт `null` в срез.
pub fn parseMetadata(arena: Allocator, bytes: []const u8) !Metadata {
    return std.json.parseFromSliceLeaky(Metadata, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Плагин, за которым стоит внешний бинарь.
pub const ExecPlugin = struct {
    name: []const u8,
    /// Абсолютный путь к бинарю.
    path: []const u8,
    /// Кэш метаданных: спрашиваются один раз за процесс.
    metadata: ?Metadata = null,
    /// Подробности последней ошибки — для диагностики пользователю. Имя
    /// ошибки Zig слишком скупо: «E_NOT_FOUND: no such secret: db/pw»
    /// говорит куда больше, чем `PluginFailed`.
    last_detail: []const u8 = "",

    /// Ищет `envee-plugin-<name>` в PATH.
    pub fn find(arena: Allocator, io: Io, path_var: []const u8, name: []const u8) Allocator.Error!?ExecPlugin {
        const path = (try lookPath(arena, io, path_var, try exeName(arena, name))) orelse return null;
        return .{ .name = name, .path = path };
    }

    /// `<bin> metadata`. Результат кэшируется в самом плагине.
    pub fn fetchMetadata(p: *ExecPlugin, arena: Allocator, io: Io, environ: ?*const Environ) Error!Metadata {
        if (p.metadata) |m| return m;
        const run = try runPlugin(arena, io, &.{ p.path, "metadata" }, environ, null, metadata_timeout_ms);
        if (!run.ok) {
            p.last_detail = try std.fmt.allocPrint(arena, "metadata: {s}", .{run.term});
            return error.PluginFailed;
        }
        const md = parseMetadata(arena, run.stdout) catch {
            p.last_detail = "parse metadata: not valid JSON";
            return error.BadResponse;
        };
        p.metadata = md;
        return md;
    }

    /// `<bin> resolve` для ссылки `ref`. Значение любого типа приводится к
    /// строке так же, как в Go: число — `%g`, логическое — `true/false`,
    /// объект — компактный JSON, отсутствие — пустая строка.
    pub fn resolveSecret(p: *ExecPlugin, arena: Allocator, io: Io, environ: *const Environ, ctx: RequestContext, ref: []const u8) Error![]const u8 {
        const body = try requestBody(arena, io, environ, ctx, ref);
        const run = try runPlugin(arena, io, &.{ p.path, "resolve" }, environ, body, resolve_timeout_ms);

        const parsed: ?std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, arena, run.stdout, .{}) catch null;
        const obj: ?std.json.ObjectMap = if (parsed) |v| (if (v == .object) v.object else null) else null;

        if (!run.ok) {
            // Плагин, упавший с ненулевым кодом, всё же мог объяснить
            // причину в ответе — тогда важнее она, а не код выхода.
            if (obj) |o| if (errorDetail(arena, o)) |d| {
                p.last_detail = d;
                return error.PluginFailed;
            };
            p.last_detail = try std.fmt.allocPrint(arena, "plugin {s}: {s}", .{ p.name, run.term });
            return error.PluginFailed;
        }
        const o = obj orelse {
            p.last_detail = "parse resolve response: not valid JSON";
            return error.BadResponse;
        };
        const status = stringField(o, "status") orelse "";
        if (!std.mem.eql(u8, status, "ok")) {
            p.last_detail = errorDetail(arena, o) orelse
                try std.fmt.allocPrint(arena, "plugin returned non-ok status: {s}", .{status});
            return error.PluginFailed;
        }
        const value = o.get("value") orelse return "";
        if (value != .object) return "";
        const inner = value.object.get("value") orelse return "";
        return valueToString(arena, inner);
    }

    fn errorDetail(arena: Allocator, o: std.json.ObjectMap) ?[]const u8 {
        const e = o.get("error") orelse return null;
        if (e != .object) return null;
        const code = stringField(e.object, "code") orelse "";
        const message = stringField(e.object, "message") orelse "";
        return std.fmt.allocPrint(arena, "{s}: {s}", .{ code, message }) catch null;
    }
};

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn valueToString(arena: Allocator, v: std.json.Value) Allocator.Error![]const u8 {
    return switch (v) {
        .null => "",
        .string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .number_string => |s| s,
        .array, .object => blk: {
            var out: Writer.Allocating = .init(arena);
            std.json.Stringify.value(v, .{}, &out.writer) catch return error.OutOfMemory;
            break :blk out.written();
        },
    };
}

/// Блок `context` запроса: где лежит конфиг, откуда вызвали и какой профиль
/// активен. Go брал это из переменных `ENVEE_*` окружения, которые в момент
/// `eval` ещё не выставлены, и плагины получали пустые строки; здесь ядро
/// передаёт то, что знает само, а переменные остаются запасным источником.
pub const RequestContext = struct {
    config_root: []const u8 = "",
    cwd: []const u8 = "",
    profile: []const u8 = "",
};

/// Тело запроса `resolve`. Порядок полей и содержимое — как у Go:
/// `api_version, request_id, spec, context{config_root, cwd, profile, env}`,
/// где `env` — всё окружение процесса с ключами по алфавиту.
fn requestBody(arena: Allocator, io: Io, environ: *const Environ, ctx: RequestContext, ref: []const u8) Allocator.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    const nanos = Io.Timestamp.now(io, .real).nanoseconds;

    write(w, "{\"api_version\":") catch return error.OutOfMemory;
    w.print("{d},\"request_id\":\"req-{d}\",\"spec\":{{\"ref\":", .{ api_version, nanos }) catch return error.OutOfMemory;
    jsonString(w, ref) catch return error.OutOfMemory;
    write(w, "},\"context\":{\"config_root\":") catch return error.OutOfMemory;
    jsonString(w, if (ctx.config_root.len > 0) ctx.config_root else environ.get("ENVEE_CONFIG_ROOT") orelse "") catch return error.OutOfMemory;
    write(w, ",\"cwd\":") catch return error.OutOfMemory;
    jsonString(w, if (ctx.cwd.len > 0) ctx.cwd else environ.get("ENVEE_CWD") orelse "") catch return error.OutOfMemory;
    write(w, ",\"profile\":") catch return error.OutOfMemory;
    jsonString(w, if (ctx.profile.len > 0) ctx.profile else environ.get("ENVEE_PROFILE") orelse "") catch return error.OutOfMemory;
    write(w, ",\"env\":{") catch return error.OutOfMemory;

    const keys = try arena.dupe([]const u8, environ.keys());
    std.mem.sort([]const u8, keys, {}, lessThan);
    for (keys, 0..) |k, i| {
        if (i > 0) write(w, ",") catch return error.OutOfMemory;
        jsonString(w, k) catch return error.OutOfMemory;
        write(w, ":") catch return error.OutOfMemory;
        jsonString(w, environ.get(k) orelse "") catch return error.OutOfMemory;
    }
    write(w, "}}}") catch return error.OutOfMemory;
    return out.written();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn write(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll(s);
}

fn jsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try std.json.Stringify.value(s, .{}, w);
}

const RunOutcome = struct {
    ok: bool,
    /// Описание завершения для сообщений: `exit status 1`, `signal 9`.
    term: []const u8,
    stdout: []const u8,
};

/// Запускает плагин, отдаёт ему `input` в stdin, собирает stdout и следит
/// за общим сроком. stderr наследуется: плагин имеет право говорить с
/// пользователем напрямую.
///
/// Срок — один на весь вызов, а не на каждое чтение: плагин, выдающий по
/// байту раз в секунду, всё равно должен быть остановлен.
fn runPlugin(
    arena: Allocator,
    io: Io,
    argv: []const []const u8,
    environ: ?*const Environ,
    input: ?[]const u8,
    timeout_ms: i64,
) Error!RunOutcome {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ,
        .stdin = if (input != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| return .{
        .ok = false,
        .term = try std.fmt.allocPrint(arena, "cannot start: {s}", .{@errorName(err)}),
        .stdout = "",
    };
    // После `wait` ничего не делает; после таймаута — убивает и дожидается.
    defer child.kill(io);

    if (input) |body| {
        const stdin = child.stdin.?;
        // Плагин мог выйти, не прочитав запрос (как fakeplugin в режиме
        // exit_nonzero): тогда труба закрыта, и это не наша ошибка.
        stdin.writeStreamingAll(io, body) catch {};
        stdin.close(io);
        child.stdin = null;
    }

    var buffer: Io.File.MultiReader.Buffer(1) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{child.stdout.?});
    defer reader.deinit();

    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    while (reader.fill(256, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return error.PluginTimeout,
        else => return .{ .ok = false, .term = @errorName(err), .stdout = "" },
    }
    reader.checkAnyError() catch |err| return .{ .ok = false, .term = @errorName(err), .stdout = "" };

    const term = child.wait(io) catch |err| return .{ .ok = false, .term = @errorName(err), .stdout = "" };
    const stdout = try reader.toOwnedSlice(0);
    return switch (term) {
        .exited => |code| .{
            .ok = code == 0,
            .term = try std.fmt.allocPrint(arena, "exit status {d}", .{code}),
            .stdout = stdout,
        },
        .signal => |sig| .{ .ok = false, .term = try std.fmt.allocPrint(arena, "signal {d}", .{@intFromEnum(sig)}), .stdout = stdout },
        else => .{ .ok = false, .term = @tagName(term), .stdout = stdout },
    };
}

// ---- диспетчер ---------------------------------------------------------------

/// Карта «источник → плагин». Именно её потребляет `directive.apply`.
pub const Dispatcher = struct {
    arena: Allocator,
    io: Io,
    environ: *const Environ,
    /// Что плагины узнают о вызове; заполняется тем, кто применяет конфиг.
    context: RequestContext = .{},
    plugins: std.StringArrayHashMapUnmanaged(ExecPlugin) = .empty,
    last_detail: []const u8 = "",

    pub fn put(d: *Dispatcher, p: ExecPlugin) Allocator.Error!void {
        try d.plugins.put(d.arena, p.name, p);
    }

    pub fn get(d: *Dispatcher, source: []const u8) ?*ExecPlugin {
        return d.plugins.getPtr(source);
    }

    pub fn resolveSecret(d: *Dispatcher, arena: Allocator, source: []const u8, ref: []const u8) Error![]const u8 {
        const p = d.get(source) orelse {
            d.last_detail = try std.fmt.allocPrint(arena, "plugin not found for source: {s}", .{source});
            return error.PluginNotFound;
        };
        return p.resolveSecret(arena, d.io, d.environ, d.context, ref) catch |err| {
            d.last_detail = p.last_detail;
            return err;
        };
    }

    pub fn resolver(d: *Dispatcher) directive.PluginResolver {
        return .{ .ctx = d, .resolveFn = resolveThunk, .detailFn = detailThunk };
    }

    fn resolveThunk(ctx: *anyopaque, arena: Allocator, source: []const u8, ref: []const u8) anyerror![]const u8 {
        const d: *Dispatcher = @ptrCast(@alignCast(ctx));
        return d.resolveSecret(arena, source, ref);
    }

    fn detailThunk(ctx: *anyopaque) []const u8 {
        const d: *Dispatcher = @ptrCast(@alignCast(ctx));
        return d.last_detail;
    }
};

/// Находит все плагины в PATH и регистрирует те, что отвечают на
/// `metadata`. Первый бинарь с данным именем в PATH выигрывает, как и у
/// любой команды.
pub fn discoverAndLoad(arena: Allocator, io: Io, environ: *const Environ) Allocator.Error!Dispatcher {
    var d: Dispatcher = .{ .arena = arena, .io = io, .environ = environ };
    const path_var = environ.get("PATH") orelse "";
    for (try discoverPaths(arena, io, path_var)) |bin| {
        const name = pluginName(bin) orelse continue;
        if (d.plugins.contains(name)) continue;
        var p: ExecPlugin = .{ .name = name, .path = bin };
        _ = p.fetchMetadata(arena, io, environ) catch continue;
        try d.put(p);
    }
    return d;
}

/// Диспетчер только тогда, когда конфигу он нужен.
///
/// Обнаружение обходит весь PATH и запускает по процессу на каждый плагин,
/// а `eval` вызывается из hook'а на каждое приглашение. Платить за это
/// конфигам без секретов нельзя: иначе установка плагина замедляла бы
/// каждый prompt, даже в проектах, которые плагином не пользуются.
pub fn dispatcherFor(arena: Allocator, io: Io, environ: *const Environ, cfg: config.Config, ctx: RequestContext) Allocator.Error!?Dispatcher {
    const refs = try cfg.secretRefs(arena);
    if (refs.len == 0) return null;
    var d = try discoverAndLoad(arena, io, environ);
    d.context = ctx;
    return d;
}

// ---- тесты -------------------------------------------------------------------
//
// Порт `internal/plugin/exec_test.go`. Поддельный плагин — `src/testing/
// fakeplugin.zig`, собранный build.zig; путь к нему приходит через
// `test_options`. Один бинарь ставится под несколькими именами: поиск идёт
// по имени файла, и разные имена позволяют привязать сбой к источнику.

const testing = std.testing;
const harness = @import("cli/test_harness.zig");

const PluginDir = struct {
    tmp: harness.TempDir,
    environ: Environ,

    fn create(arena: Allocator, mode: []const u8) !PluginDir {
        const io = testing.io;
        const tmp = try harness.TempDir.create(arena);
        const fake_path = @import("test_options").fake_plugin;
        const bin = try Io.Dir.cwd().readFileAlloc(io, fake_path, arena, .unlimited);

        for ([_][]const u8{ "fake", "alpha", "beta" }) |alias| {
            const dst = try tmp.join(arena, try exeName(arena, alias));
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });
        }
        // Неисполняемый файл и посторонний бинарь обнаружение обязано
        // пропустить.
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try tmp.join(arena, "envee-plugin-notexec"), .data = "#!/bin/sh\n", .flags = .{ .permissions = perms.fromMode(0o644) } });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try tmp.join(arena, "unrelated-binary"), .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });

        // PATH указывает ТОЛЬКО на этот каталог: настоящие плагины
        // разработчика не должны влиять на результат.
        var environ: Environ = .init(arena);
        try environ.put("PATH", tmp.path);
        try environ.put("HOME", tmp.path);
        if (mode.len > 0) try environ.put("FAKE_PLUGIN_MODE", mode);
        return .{ .tmp = tmp, .environ = environ };
    }

    fn destroy(d: PluginDir) void {
        d.tmp.destroy();
    }

    fn path(d: *const PluginDir) []const u8 {
        return d.environ.get("PATH").?;
    }

    fn plugin(d: *const PluginDir, arena: Allocator, name: []const u8) !ExecPlugin {
        return (try ExecPlugin.find(arena, testing.io, d.path(), name)) orelse error.PluginMissing;
    }
};

test "a plugin that is not on PATH is not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();

    try testing.expect((try ExecPlugin.find(a, testing.io, d.path(), "definitely-not-installed")) == null);
}

test "metadata is fetched, parsed and cached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();

    var p = try d.plugin(a, "fake");
    const md = try p.fetchMetadata(a, testing.io, &d.environ);
    try testing.expectEqualStrings("fake", md.name);
    try testing.expectEqualStrings("9.9.9", md.version);
    try testing.expectEqual(@as(i64, 1), md.api_version);
    try testing.expectEqual(@as(usize, 1), md.capabilities.?.len);
    try testing.expectEqualStrings("secret", md.capabilities.?[0]);

    // Ломаем путь: кэшированный результат обязан вернуться и без бинаря.
    p.path = try d.tmp.join(a, "does-not-exist");
    const again = try p.fetchMetadata(a, testing.io, &d.environ);
    try testing.expectEqualStrings("fake", again.name);
}

test "garbage or a non-zero exit from metadata is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const garbage = try PluginDir.create(a, "garbage");
    defer garbage.destroy();
    var p = try garbage.plugin(a, "fake");
    try testing.expectError(error.BadResponse, p.fetchMetadata(a, testing.io, &garbage.environ));

    const failing = try PluginDir.create(a, "exit_nonzero");
    defer failing.destroy();
    var q = try failing.plugin(a, "fake");
    try testing.expectError(error.PluginFailed, q.fetchMetadata(a, testing.io, &failing.environ));
    try testing.expect(std.mem.indexOf(u8, q.last_detail, "exit status 1") != null);
}

test "resolve returns the plugin's value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();

    var p = try d.plugin(a, "fake");
    try testing.expectEqualStrings("resolved:my/ref", try p.resolveSecret(a, testing.io, &d.environ, .{}, "my/ref"));
}

test "non-string values are rendered the way Go renders them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][2][]const u8{
        .{ "int_value", "42" },
        .{ "bool_value", "true" },
        .{ "json_value", "{\"a\":1}" },
        .{ "null_value", "" },
    };
    for (cases) |c| {
        const d = try PluginDir.create(a, c[0]);
        defer d.destroy();
        var p = try d.plugin(a, "fake");
        try testing.expectEqualStrings(c[1], try p.resolveSecret(a, testing.io, &d.environ, .{}, "r"));
    }
}

test "an error response keeps the plugin's own message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "error_response");
    defer d.destroy();

    var p = try d.plugin(a, "fake");
    try testing.expectError(error.PluginFailed, p.resolveSecret(a, testing.io, &d.environ, .{}, "missing/ref"));
    // Без этого пользователю не сказали бы, почему секрет не достался.
    try testing.expect(std.mem.indexOf(u8, p.last_detail, "E_NOT_FOUND") != null);
    try testing.expect(std.mem.indexOf(u8, p.last_detail, "missing/ref") != null);
}

test "a non-ok status or garbage output is never a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const degraded = try PluginDir.create(a, "status_not_ok");
    defer degraded.destroy();
    var p = try degraded.plugin(a, "fake");
    try testing.expectError(error.PluginFailed, p.resolveSecret(a, testing.io, &degraded.environ, .{}, "r"));
    try testing.expect(std.mem.indexOf(u8, p.last_detail, "degraded") != null);

    const garbage = try PluginDir.create(a, "garbage");
    defer garbage.destroy();
    var q = try garbage.plugin(a, "fake");
    try testing.expectError(error.BadResponse, q.resolveSecret(a, testing.io, &garbage.environ, .{}, "r"));
}

// Плагин, который никогда не отвечает, не должен подвешивать hook оболочки.
test "a hanging plugin is killed after the deadline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "hang");
    defer d.destroy();

    const p = try d.plugin(a, "fake");
    const started = Io.Timestamp.now(testing.io, .awake).nanoseconds;
    const body = try requestBody(a, testing.io, &d.environ, .{}, "r");
    const outcome = runPlugin(a, testing.io, &.{ p.path, "resolve" }, &d.environ, body, 300);
    const elapsed_ms = @divTrunc(Io.Timestamp.now(testing.io, .awake).nanoseconds - started, std.time.ns_per_ms);

    try testing.expectError(error.PluginTimeout, outcome);
    try testing.expect(elapsed_ms < 10_000);
}

test "the resolve request has the Go layout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: Environ = .init(a);
    try environ.put("ZED", "last");
    try environ.put("ALPHA", "first");
    try environ.put("ENVEE_PROFILE", "dev");
    const body = try requestBody(a, testing.io, &environ, .{}, "op://x/y");

    try testing.expect(std.mem.startsWith(u8, body, "{\"api_version\":1,\"request_id\":\"req-"));
    try testing.expect(std.mem.indexOf(u8, body, "\"spec\":{\"ref\":\"op://x/y\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"context\":{\"config_root\":\"\",\"cwd\":\"\",\"profile\":\"dev\",\"env\":{\"ALPHA\":\"first\",\"ENVEE_PROFILE\":\"dev\",\"ZED\":\"last\"}}}") != null);

    // Контекст от ядра важнее переменных окружения: он знает активный
    // профиль и каталог конфига, а переменные в момент eval ещё не выставлены.
    const with_ctx = try requestBody(a, testing.io, &environ, .{ .config_root = "/proj", .cwd = "/proj/sub", .profile = "prod" }, "r");
    try testing.expect(std.mem.indexOf(u8, with_ctx, "\"context\":{\"config_root\":\"/proj\",\"cwd\":\"/proj/sub\",\"profile\":\"prod\",") != null);

    // Это и валидный JSON.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try testing.expect(v == .object);
}

test "discovery finds every executable envee-plugin-* and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();

    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try discoverPaths(a, testing.io, d.path())) |p| {
        try names.put(a, pluginName(p) orelse "", {});
    }
    for ([_][]const u8{ "fake", "alpha", "beta" }) |want| {
        try testing.expect(names.contains(want));
    }
    try testing.expect(!names.contains("notexec"));
    try testing.expect(!names.contains(""));
    try testing.expect(!names.contains("unrelated-binary"));
}

// Метаданные настоящего envee-plugin-env (Go v0.1.0), дословно. Go пишет
// `null` вместо пустого списка, и это не должно ронять разбор.
test "metadata from the Go env plugin parses, null lists included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md = try parseMetadata(a,
        \\{"name":"env","version":"0.1.0","api_version":1,"description":"Local key-value secret store (envee secret set/unset/list)","capabilities":["secret"],"permissions":{"network":false,"filesystem":["$XDG_DATA_HOME/envee/secrets/env.json"],"exec":null}}
    );
    try testing.expectEqualStrings("env", md.name);
    try testing.expectEqual(@as(usize, 1), md.permissions.filesystem.?.len);
    try testing.expect(md.permissions.exec == null);
    try testing.expect(!md.permissions.network);

    // Минимальный ответ тоже годится: всё необязательное — по умолчанию.
    const bare = try parseMetadata(a, "{\"name\":\"x\"}");
    try testing.expectEqualStrings("x", bare.name);
    try testing.expect(bare.capabilities == null);

    // И обратно в JSON — в форме Go, с `null` там, где он был.
    var out: Writer.Allocating = .init(a);
    try writeMetadataJson(&out.writer, md, 0);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "env",
        \\  "version": "0.1.0",
        \\  "api_version": 1,
        \\  "description": "Local key-value secret store (envee secret set/unset/list)",
        \\  "capabilities": [
        \\    "secret"
        \\  ],
        \\  "permissions": {
        \\    "network": false,
        \\    "filesystem": [
        \\      "$XDG_DATA_HOME/envee/secrets/env.json"
        \\    ],
        \\    "exec": null
        \\  }
        \\}
    , out.written());
}

test "plugin names are the suffix after the prefix" {
    try testing.expectEqualStrings("op", pluginName("/usr/local/bin/envee-plugin-op").?);
    try testing.expectEqualStrings("vault", pluginName("envee-plugin-vault").?);
    try testing.expect(pluginName("/bin/envee-plugin-") == null);
    try testing.expect(pluginName("/bin/not-a-plugin") == null);
}

test "exe names are not prefixed twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("envee-plugin-op", try exeName(a, "op"));
    try testing.expectEqualStrings("envee-plugin-op", try exeName(a, "envee-plugin-op"));
}

test "the dispatcher routes by source and names an unknown one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();

    var disp = try discoverAndLoad(a, testing.io, &d.environ);
    try testing.expectEqual(@as(usize, 3), disp.plugins.count());
    try testing.expectEqualStrings("resolved:some/ref", try disp.resolveSecret(a, "beta", "some/ref"));

    try testing.expectError(error.PluginNotFound, disp.resolveSecret(a, "nope", "r"));
    try testing.expectEqualStrings("plugin not found for source: nope", disp.last_detail);

    // Через интерфейс directive подробности тоже доходят.
    const r = disp.resolver();
    try testing.expectError(error.PluginNotFound, r.resolve(a, "nope", "r"));
    try testing.expectEqualStrings("plugin not found for source: nope", r.detail(error.PluginNotFound));
}

test "a plugin error propagates through the dispatcher with its detail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "error_response");
    defer d.destroy();

    var disp = try discoverAndLoad(a, testing.io, &d.environ);
    try testing.expectError(error.PluginFailed, disp.resolveSecret(a, "alpha", "r"));
    try testing.expect(std.mem.indexOf(u8, disp.last_detail, "E_NOT_FOUND") != null);
}

test "a config without secrets gets no dispatcher at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ: Environ = .init(a);
    // PATH намеренно указывает в никуда: если бы обнаружение всё же
    // запустилось, оно бы просто ничего не нашло, но здесь важнее то, что
    // оно не должно запускаться вовсе.
    try environ.put("PATH", "/nonexistent");

    const cfg = try config.parseBytes(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nA = \"1\"\n", null);
    try testing.expect((try dispatcherFor(a, testing.io, &environ, cfg, .{})) == null);

    const with_secret = try config.parseBytes(a, "envee.toml", "schema = \"envee/v1\"\n[env]\nA = { source = \"fake\", ref = \"r\" }\n", null);
    try testing.expect((try dispatcherFor(a, testing.io, &environ, with_secret, .{})) != null);
}

// Сквозная проверка: конфиг с секретом → eval → плагин вызван, значение в
// оболочке, а отказ обязательного секрета объясняется словами плагина.
test "eval resolves secrets through a discovered plugin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try PluginDir.create(a, "");
    defer d.destroy();
    try d.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\PLAIN = "1"
        \\TOKEN = { source = "alpha", ref = "team/token", required = true }
        \\
        \\[env._.secret.DB]
        \\source = "beta"
        \\ref = "db/pw"
        \\redact = true
        \\
    );
    const path_pair = [2][]const u8{ "PATH", d.path() };

    const out = try harness.run(a, d.tmp, &.{ "eval", "bash" }, &.{path_pair});
    try testing.expect(std.mem.indexOf(u8, out, "export TOKEN=resolved:team/token;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "export DB=resolved:db/pw;") != null);

    // Необязательный секрет, который не достался, просто пропускается…
    const errs_mod = @import("errs.zig");
    const failing = [2][]const u8{ "FAKE_PLUGIN_MODE", "error_response" };
    try d.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\OPTIONAL = { source = "alpha", ref = "nope" }
        \\
    );
    const relaxed = try harness.run(a, d.tmp, &.{ "eval", "bash" }, &.{ path_pair, failing });
    try testing.expect(std.mem.indexOf(u8, relaxed, "OPTIONAL") == null);

    // …а обязательный — E004 с сообщением самого плагина.
    try d.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\MUST = { source = "alpha", ref = "nope", required = true }
        \\
    );
    errs_mod.reset();
    try testing.expectError(error.PluginFailed, harness.run(a, d.tmp, &.{ "eval", "bash" }, &.{ path_pair, failing }));
    const diag = errs_mod.take().?;
    try testing.expectEqual(errs_mod.Code.e004, diag.code);
    try testing.expectEqualStrings("E_NOT_FOUND: no such secret: nope", diag.cause_text);
    var found = false;
    for (diag.context) |kv| {
        if (std.mem.eql(u8, kv.key, "source") and std.mem.eql(u8, kv.value, "alpha")) found = true;
    }
    try testing.expect(found);

    // Источник без плагина — тоже E004, и в подробностях назван источник.
    try d.tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\MUST = { source = "vault", ref = "x", required = true }
        \\
    );
    errs_mod.reset();
    try testing.expectError(error.PluginFailed, harness.run(a, d.tmp, &.{ "eval", "bash" }, &.{path_pair}));
    const missing = errs_mod.take().?;
    try testing.expectEqualStrings("plugin not found for source: vault", missing.cause_text);
}

// Совместимость с чужими плагинами: демонстрационный плагин из Go SDK
// (`pkg/sdk-go/testdata/demoplugin`) собирается `go build` и резолвится
// этим ядром. Без `go` в PATH тест пропускается, а не падает: он про
// протокол, а не про наличие Go на машине.
test "a plugin built on the Go SDK resolves through the Zig core" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const bin = try tmp.join(a, "envee-plugin-demo");
    // SDK — отдельный Go-модуль, поэтому сборка идёт из его каталога.
    const build = std.process.run(a, io, .{
        .argv = &.{ "go", "build", "-o", bin, "./testdata/demoplugin" },
        .cwd = .{ .path = "pkg/sdk-go" },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    if (build.term != .exited or build.term.exited != 0) return error.SkipZigTest;

    var environ: Environ = .init(a);
    try environ.put("PATH", tmp.path);
    var disp = try discoverAndLoad(a, io, &environ);
    const demo = disp.get("demo") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.2.3", demo.metadata.?.version);
    try testing.expectEqualStrings("value-for-db/password", try disp.resolveSecret(a, "demo", "db/password"));

    // И его структурная ошибка доходит с кодом.
    try environ.put("DEMO_MODE", "plugin_error");
    try testing.expectError(error.PluginFailed, disp.resolveSecret(a, "demo", "missing"));
    try testing.expect(std.mem.indexOf(u8, disp.last_detail, "E_NO_SUCH_SECRET: no secret named missing") != null);
}
