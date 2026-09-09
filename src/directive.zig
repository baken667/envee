//! Применение директив: из разобранного конфига получить готовое окружение.
//!
//! Порт `internal/directive/directive.go` и `internal/directive/path.go`.
//!
//! Порядок наложения слоёв (каждый следующий перекрывает предыдущий):
//!   1. `_.file` — переменные из внешних файлов
//!   2. переменные активного профиля
//!   3. таблица `[env]`
//!   4. `_.path` — каталоги для $PATH
//!   5. шаблоны `{{...}}` в топологическом порядке, с поиском циклов
//!   6. шаблоны внутри `_.path`
//!   7. секреты через плагин
//!   8. проверка `required`
//!   9. запрет на переменные `ENVEE_*`
//!
//! ВНИМАНИЕ, отличие от Go-версии по ПОВЕДЕНИЮ. Go проверял `required` на
//! шаге 2, ДО того как применял переменные самого профиля и таблицу `[env]`.
//! Из-за этого `required = ["X"]` падало даже тогда, когда X объявлен тут же,
//! в `[profiles.<name>.env]`. Проверено на выпущенной версии: поставляемый
//! `examples/multi-profile/envee.toml` с `--profile prod` падал с E008 на
//! своей же переменной DATABASE_URL. Здесь проверка стоит в конце, когда все
//! источники значений отработали.
//!
//! Владение: результат выделяется из переданной арены.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const env_mod = @import("env.zig");
const file_mod = @import("directive/file.zig");
const gopath = @import("path.zig");
const template = @import("template.zig");
const value = @import("toml/value.zig");

pub const Env = env_mod.Map;

/// Префикс, закреплённый за самим envee.
///
/// envee выгружает всё, что произвёл конфиг, прямо в оболочку пользователя.
/// Позволь конфигу задавать `ENVEE_*` — и он настраивал бы сам envee для
/// всех последующих каталогов сессии: конфиг одного проекта менял бы
/// поведение во всех остальных. Проверка стоит в конце и потому покрывает
/// все источники сразу: TOML, профили, файлы `_.file` и плагины секретов.
pub const reserved_prefix = "ENVEE_";

pub const Result = struct {
    env: Env,
    /// Каталоги, уходящие в начало $PATH, в порядке добавления.
    path_prepend: []const []const u8,

    /// Переменные, значения которых нельзя показывать.
    pub fn redactedKeys(r: Result, gpa: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (r.env.entries.items) |e| {
            if (e.redacted) try out.append(gpa, e.key);
        }
        return out.toOwnedSlice(gpa);
    }
};

pub const Options = struct {
    /// Каталог, в котором лежит конфиг.
    config_root: []const u8,
    /// Активный профиль; пустая строка — профиль не применяется.
    profile: []const u8 = "",
    /// Текущий рабочий каталог для шаблона `{{cwd}}`.
    cwd: []const u8 = "",
    /// Окружение процесса для шаблонов `{{env.X}}`.
    os_env: *const Env,
};

/// Разрешение секретов через плагин. Структура с указателем на функцию, а не
/// интерфейс: набор реализаций закрыт, а связывать directive с plugin по
/// типам не хочется.
pub const PluginResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (
        ctx: *anyopaque,
        arena: Allocator,
        source: []const u8,
        ref: []const u8,
    ) anyerror![]const u8,

    pub fn resolve(
        p: PluginResolver,
        arena: Allocator,
        source: []const u8,
        ref: []const u8,
    ) anyerror![]const u8 {
        return p.resolveFn(p.ctx, arena, source, ref);
    }
};

pub const Error = error{
    /// Шаблоны ссылаются друг на друга по кругу.
    CycleDetected,
    /// Переменная объявлена обязательной, но не определена.
    RequiredVarMissing,
    /// Конфиг пытается задать переменную из пространства имён envee.
    ReservedKey,
    /// Сокращённая запись секрета без обязательного поля `ref`.
    SecretMissingRef,
    /// Обязательный секрет не разрешился.
    SecretFailed,
} || file_mod.Error || template.RenderError;

pub const Diagnostics = struct {
    /// Переменная или ключ, на котором споткнулись.
    key: []const u8 = "",
    /// Цепочка для цикла, источник для секрета и т.п.
    detail: []const u8 = "",
    profile: []const u8 = "",
    file: file_mod.Diagnostics = .{},
};

pub fn apply(
    arena: Allocator,
    io: std.Io,
    cfg: config.Config,
    opts: Options,
    resolver: ?PluginResolver,
    diag: ?*Diagnostics,
) Error!Result {
    var res: Result = .{ .env = .empty, .path_prepend = &.{} };
    const cwd = if (opts.cwd.len > 0) opts.cwd else opts.config_root;

    // 1. Файлы, в порядке объявления: следующий перекрывает предыдущий.
    for (cfg.directives.file) |ref| {
        var sink_ctx: FileSink = .{ .arena = arena, .env = &res.env, .ref = ref };
        var file_diag: file_mod.Diagnostics = .{};
        file_mod.applyFile(arena, io, opts.config_root, ref, opts.os_env, sink_ctx.sink(), &file_diag) catch |err| {
            if (diag) |d| d.file = file_diag;
            return err;
        };
    }

    // 2. Переменные активного профиля.
    if (opts.profile.len > 0) {
        if (cfg.profileByName(opts.profile)) |prof| {
            const source = try std.fmt.allocPrint(arena, "profile:{s}", .{opts.profile});
            for (prof.env.keys(), prof.env.map.values()) |k, v| {
                const coerced = try coerce(arena, v);
                try res.env.setEntry(arena, .{
                    .key = k,
                    .value = coerced.text,
                    .redacted = coerced.redact,
                    .source = source,
                });
            }
        }
    }

    // 3. Таблица [env] — высший приоритет среди значений.
    var shorthand: std.ArrayList(config.NamedSecret) = .empty;
    for (cfg.env.keys(), cfg.env.map.values()) |k, v| {
        if (std.mem.eql(u8, k, "_") or config.isMetaKey(k)) continue;

        // Сокращённая запись секрета: { source = "...", ref = "..." }.
        // Значением она не становится — её разрешает шаг 7.
        if (v.asTable()) |t| {
            if (t.get("source")) |src_val| {
                if (src_val.asString()) |src| {
                    if (src.len > 0) {
                        const ref_text = if (t.get("ref")) |r| (r.asString() orelse "") else "";
                        if (ref_text.len == 0) {
                            if (diag) |d| d.key = k;
                            return error.SecretMissingRef;
                        }
                        try shorthand.append(arena, .{ .name = k, .ref = .{
                            .source = src,
                            .ref = ref_text,
                            .redact = if (t.get("redact")) |b| (b.asBool() orelse false) else false,
                            .required = if (t.get("required")) |b| (b.asBool() orelse false) else false,
                        } });
                        continue;
                    }
                }
            }
        }

        const coerced = try coerce(arena, v);
        try res.env.setEntry(arena, .{
            .key = k,
            .value = coerced.text,
            .redacted = coerced.redact,
            .source = "toml",
        });
    }

    // 4. Каталоги для $PATH. Относительный путь без шаблона сразу
    //    достраивается до абсолютного; путь с шаблоном станет абсолютным
    //    после подстановки на шаге 6.
    var prepend: std.ArrayList([]const u8) = .empty;
    for (cfg.directives.path) |p| {
        // gopath.join нормализует результат: без этого "./bin" даёт
        // "<config_root>/./bin", и этот мусор уезжает прямо в $PATH.
        const path = if (!std.fs.path.isAbsolute(p.path) and
            std.mem.indexOf(u8, p.path, "{{") == null)
            try gopath.join(arena, &.{ opts.config_root, p.path })
        else
            p.path;
        try prepend.append(arena, path);
    }
    res.path_prepend = try prepend.toOwnedSlice(arena);

    // 5. Шаблоны в значениях.
    try evaluateTemplates(arena, io, &res, opts, cwd, diag);

    // 6. Шаблоны в каталогах $PATH.
    try expandPathTemplates(arena, io, &res, opts, cwd, diag);

    // 7. Секреты: сначала объявленные таблицей, затем сокращённые.
    try applySecrets(arena, cfg.directives.secret, resolver, &res, diag);
    try applySecrets(arena, shorthand.items, resolver, &res, diag);

    // 8. Обязательные переменные — только теперь, когда отработали ВСЕ
    //    источники значений. См. шапку файла.
    if (opts.profile.len > 0) {
        if (cfg.profileByName(opts.profile)) |prof| {
            for (prof.required) |name| {
                if (res.env.get(name) == null) {
                    if (diag) |d| d.* = .{ .key = name, .profile = opts.profile };
                    return error.RequiredVarMissing;
                }
            }
        }
    }

    // 9. Пространство имён envee закрыто для конфигов.
    for (res.env.entries.items) |e| {
        if (std.mem.startsWith(u8, e.key, reserved_prefix)) {
            if (diag) |d| d.key = e.key;
            return error.ReservedKey;
        }
    }

    return res;
}

/// Приёмник для директивы `_.file`.
const FileSink = struct {
    arena: Allocator,
    env: *Env,
    ref: config.FileRef,

    fn sink(f: *FileSink) file_mod.Sink {
        return .{ .ctx = f, .setFn = set };
    }

    fn set(ctx: *anyopaque, key: []const u8, val: []const u8) Allocator.Error!void {
        const self: *FileSink = @ptrCast(@alignCast(ctx));
        try self.env.setEntry(self.arena, .{
            .key = key,
            .value = val,
            .redacted = self.ref.redact,
            .source = try std.fmt.allocPrint(self.arena, "file:{s}", .{self.ref.path}),
        });
    }
};

const Coerced = struct {
    text: []const u8,
    redact: bool,
};

/// Приводит значение из TOML к строке.
///
/// Отдельно разбирается inline-таблица `{ value = ..., redact = true }`:
/// значение берётся из поля `value`, а `redact` — метка, которая поедет
/// вместе с переменной.
fn coerce(arena: Allocator, v: value.Value) Allocator.Error!Coerced {
    switch (v) {
        .string => |s| return .{ .text = s, .redact = false },
        .integer => |i| return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{i}), .redact = false },
        .boolean => |b| return .{ .text = if (b) "true" else "false", .redact = false },
        .float => |f| return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{f}), .redact = false },
        .array => |items| return .{ .text = try formatArray(arena, items), .redact = false },
        .table => |t| {
            const redact = if (t.get("redact")) |b| (b.asBool() orelse false) else false;
            const inner = t.get("value") orelse return .{ .text = "", .redact = redact };
            const text = switch (inner) {
                .string => |s| s,
                .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
                .boolean => |b| if (b) "true" else "false",
                .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
                .array => |items| try formatArray(arena, items),
                .table => "",
            };
            return .{ .text = text, .redact = redact };
        },
    }
}

/// Массив в значении переменной: `[a, b]`.
///
/// Разделитель здесь — запятая с пробелом, а в `_.file` при разворачивании
/// вложенных структур — просто пробел. Это два разных места, и оба видны
/// пользователю; расхождение унаследовано от Go-эталона.
fn formatArray(arena: Allocator, items: []value.Value) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        switch (item) {
            .string => |s| try out.appendSlice(arena, s),
            .integer => |n| try appendFmt(arena, &out, "{d}", .{n}),
            .float => |f| try appendFmt(arena, &out, "{d}", .{f}),
            .boolean => |b| try out.appendSlice(arena, if (b) "true" else "false"),
            .array => try out.appendSlice(arena, "[]"),
            .table => try out.appendSlice(arena, "map[]"),
        }
    }
    try out.append(arena, ']');
    return out.toOwnedSlice(arena);
}

fn appendFmt(arena: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const text = try std.fmt.allocPrint(arena, fmt, args);
    defer arena.free(text);
    try out.appendSlice(arena, text);
}

/// Подставляет шаблоны во все значения, в топологическом порядке.
///
/// Порядок нужен, чтобы `A = "{{env.B}}"` увидел уже подставленное значение
/// B, а не исходный шаблон.
fn evaluateTemplates(
    arena: Allocator,
    io: std.Io,
    res: *Result,
    opts: Options,
    cwd: []const u8,
    diag: ?*Diagnostics,
) Error!void {
    const order = try topoSort(arena, res.env, diag);

    // Контекст обновляется по ходу: каждое подставленное значение становится
    // видимым для следующих.
    var rendered_env: Env = .empty;
    for (res.env.entries.items) |e| try rendered_env.set(arena, e.key, e.value);

    var out: Env = .empty;
    for (order) |key| {
        // В порядок попадают и внешние имена (переменные окружения), которых
        // в нашем наборе нет, — их пропускаем.
        const entry = res.env.getEntry(key) orelse continue;

        const ctx: template.Context = .{
            .config_root = opts.config_root,
            .profile = opts.profile,
            .cwd = cwd,
            .vars = &rendered_env,
            .os_env = opts.os_env,
        };
        const text = try template.render(arena, io, entry.value, ctx, null);

        // `false` в TOML — это не значение, а команда «снять переменную».
        // Только для [env]: значение из профиля или из .env-файла остаётся
        // строкой "false".
        if (std.mem.eql(u8, text, "false") and std.mem.eql(u8, entry.source, "toml")) {
            try rendered_env.set(arena, key, text);
            continue;
        }

        var updated = entry;
        updated.value = text;
        try out.setEntry(arena, updated);
        try rendered_env.set(arena, key, text);
    }
    res.env = out;
}

fn expandPathTemplates(
    arena: Allocator,
    io: std.Io,
    res: *Result,
    opts: Options,
    cwd: []const u8,
    _: ?*Diagnostics,
) Error!void {
    if (res.path_prepend.len == 0) return;

    var vars: Env = .empty;
    for (res.env.entries.items) |e| try vars.set(arena, e.key, e.value);

    const ctx: template.Context = .{
        .config_root = opts.config_root,
        .profile = opts.profile,
        .cwd = cwd,
        .vars = &vars,
        .os_env = opts.os_env,
    };
    const out = try arena.alloc([]const u8, res.path_prepend.len);
    for (res.path_prepend, out) |p, *slot| {
        slot.* = try template.render(arena, io, p, ctx, null);
    }
    res.path_prepend = out;
}

fn applySecrets(
    arena: Allocator,
    secrets: []const config.NamedSecret,
    resolver: ?PluginResolver,
    res: *Result,
    diag: ?*Diagnostics,
) Error!void {
    for (secrets) |s| {
        const r = resolver orelse {
            // Без плагина значение подменяется заглушкой и помечается
            // скрытым: показывать «__UNRESOLVED__» вместо секрета можно,
            // но выглядеть оно должно как секрет.
            try res.env.setEntry(arena, .{
                .key = s.name,
                .value = try std.fmt.allocPrint(arena, "__UNRESOLVED__:{s}:{s}", .{ s.ref.source, s.ref.ref }),
                .redacted = true,
                .source = "secret:unresolved",
            });
            continue;
        };

        const val = r.resolve(arena, s.ref.source, s.ref.ref) catch |err| {
            // Необязательный секрет, который не достался, просто
            // пропускается: плагин может быть не настроен, и это не повод
            // ломать всю оболочку.
            if (!s.ref.required) continue;
            if (diag) |d| d.* = .{ .key = s.name, .detail = @errorName(err) };
            return error.SecretFailed;
        };
        try res.env.setEntry(arena, .{
            .key = s.name,
            .value = val,
            .redacted = s.ref.redact,
            .source = try std.fmt.allocPrint(arena, "secret:{s}", .{s.ref.source}),
        });
    }
}

/// Топологическая сортировка переменных по ссылкам в шаблонах.
///
/// Обход детерминирован: ключи перебираются по алфавиту, поэтому и порядок
/// подстановки, и сообщение об ошибке одинаковы от запуска к запуску.
fn topoSort(arena: Allocator, e: Env, diag: ?*Diagnostics) Error![]const []const u8 {
    var order: std.ArrayList([]const u8) = .empty;
    var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
    var in_stack: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (e.entries.items) |entry| {
        try visit(arena, e, entry.key, &order, &visited, &in_stack, diag);
    }
    return order.toOwnedSlice(arena);
}

fn visit(
    arena: Allocator,
    e: Env,
    key: []const u8,
    order: *std.ArrayList([]const u8),
    visited: *std.StringArrayHashMapUnmanaged(void),
    in_stack: *std.StringArrayHashMapUnmanaged(void),
    diag: ?*Diagnostics,
) Error!void {
    if (in_stack.contains(key)) {
        if (diag) |d| d.* = .{ .key = key, .detail = try cycleChain(arena, in_stack.keys(), key) };
        return error.CycleDetected;
    }
    if (visited.contains(key)) return;
    try visited.put(arena, key, {});
    try in_stack.put(arena, key, {});

    if (e.get(key)) |text| {
        for (try template.extractVarRefs(arena, text)) |dep| {
            try visit(arena, e, dep, order, visited, in_stack, diag);
        }
    }

    _ = in_stack.orderedRemove(key);
    try order.append(arena, key);
}

/// Собирает читаемую цепочку `A -> B -> A`.
///
/// Go на этом месте отдавал цепочку из одного элемента, то есть не говорил,
/// через что именно замкнулся круг.
fn cycleChain(arena: Allocator, stack: []const []const u8, key: []const u8) Allocator.Error![]const u8 {
    var start: usize = 0;
    for (stack, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            start = i;
            break;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    for (stack[start..]) |k| {
        if (out.items.len > 0) try out.appendSlice(arena, " -> ");
        try out.appendSlice(arena, k);
    }
    try out.appendSlice(arena, " -> ");
    try out.appendSlice(arena, key);
    return out.toOwnedSlice(arena);
}

// ---- $PATH -----------------------------------------------------------------

/// Добавляет каталоги в начало $PATH, отбрасывая уже присутствующие.
///
/// Порядок `dirs` сохраняется: первый элемент оказывается первым в PATH и,
/// значит, просматривается раньше остальных.
pub fn prependToPath(
    arena: Allocator,
    dirs: []const []const u8,
    current: []const u8,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);

    var it = std.mem.splitScalar(u8, current, ':');
    while (it.next()) |d| try seen.put(arena, d, {});

    for (dirs) |d| {
        if (seen.contains(d)) continue;
        try seen.put(arena, d, {});
        if (out.items.len > 0) try out.append(arena, ':');
        try out.appendSlice(arena, d);
    }
    if (current.len > 0) {
        if (out.items.len > 0) try out.append(arena, ':');
        try out.appendSlice(arena, current);
    }
    return out.toOwnedSlice(arena);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

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

    fn write(t: TempDir, gpa: Allocator, sub: []const u8, body: []const u8) !void {
        const full = try std.fs.path.join(gpa, &.{ t.path, sub });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = full, .data = body });
    }
};

/// Разбирает конфиг и применяет директивы за один шаг.
fn run(
    arena: Allocator,
    dir: TempDir,
    src: []const u8,
    profile: []const u8,
    os_pairs: []const [2][]const u8,
) !Result {
    var os_env: Env = .empty;
    for (os_pairs) |p| try os_env.set(arena, p[0], p[1]);

    const cfg = try config.parseBytes(arena, "envee.toml", src, null);
    return apply(arena, std.testing.io, cfg, .{
        .config_root = dir.path,
        .profile = profile,
        .os_env = &os_env,
    }, null, null);
}

test "values of every type become strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\PORT = 5432
        \\DEBUG = true
        \\ORIGINS = ["http://a", "http://b"]
        \\API_KEY = { value = "dev-key", redact = true }
        \\POOL = { value = 10 }
    , "", &.{});

    try testing.expectEqualStrings("myapp", res.env.get("SERVICE_NAME").?);
    try testing.expectEqualStrings("5432", res.env.get("PORT").?);
    try testing.expectEqualStrings("true", res.env.get("DEBUG").?);
    try testing.expectEqualStrings("[http://a, http://b]", res.env.get("ORIGINS").?);
    try testing.expectEqualStrings("dev-key", res.env.get("API_KEY").?);
    try testing.expectEqualStrings("10", res.env.get("POOL").?);
    // Метка redact едет вместе с переменной.
    try testing.expect(res.env.getEntry("API_KEY").?.redacted);
    try testing.expect(!res.env.getEntry("PORT").?.redacted);
}

// `false` в [env] — не значение, а команда снять переменную.
test "false in the env table unsets the variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\VERBOSE = false
        \\DEBUG = true
    , "", &.{});
    try testing.expect(res.env.get("VERBOSE") == null);
    try testing.expectEqualStrings("true", res.env.get("DEBUG").?);
}

// А из профиля или из .env-файла "false" — обычная строка.
test "false from a profile stays a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[profiles.dev.env]
        \\SEED = false
    , "dev", &.{});
    try testing.expectEqualStrings("false", res.env.get("SEED").?);
}

test "layers: file, then profile, then the env table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, ".env", "SHARED=from-file\nONLY_FILE=f\n");

    const res = try run(a, tmp,
        \\[env]
        \\_.file = ".env"
        \\SHARED = "from-toml"
        \\
        \\[profiles.dev.env]
        \\SHARED = "from-profile"
        \\ONLY_PROFILE = "p"
    , "dev", &.{});

    // Таблица [env] перекрывает и профиль, и файл.
    try testing.expectEqualStrings("from-toml", res.env.get("SHARED").?);
    try testing.expectEqualStrings("f", res.env.get("ONLY_FILE").?);
    try testing.expectEqualStrings("p", res.env.get("ONLY_PROFILE").?);
}

test "path entries become absolute and keep their order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\_.path = ["./bin", "{{config_root}}/node_modules/.bin", "/already/absolute"]
    , "", &.{});

    try testing.expectEqual(@as(usize, 3), res.path_prepend.len);
    for (res.path_prepend) |p| try testing.expect(std.fs.path.isAbsolute(p));
    try testing.expectEqualStrings(try gopath.join(a, &.{ tmp.path, "bin" }), res.path_prepend[0]);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{s}/node_modules/.bin", .{tmp.path}),
        res.path_prepend[1],
    );
    try testing.expectEqualStrings("/already/absolute", res.path_prepend[2]);
}

test "templates see config_root, profile and the environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\LOG_PATH = "{{config_root}}/logs/{{profile}}.log"
        \\DATABASE_URL = "postgres://{{env.HOST}}/{{env.DB}}"
    , "dev", &.{ .{ "HOST", "localhost" }, .{ "DB", "mydb" } });

    try testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{s}/logs/dev.log", .{tmp.path}),
        res.env.get("LOG_PATH").?,
    );
    try testing.expectEqualStrings("postgres://localhost/mydb", res.env.get("DATABASE_URL").?);
}

// Переменная, ссылающаяся на другую, обязана увидеть уже подставленное
// значение — ради этого и нужен топологический порядок.
test "one variable can build on another" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\ZZZ_LAST = "{{env.MIDDLE}}/deep"
        \\MIDDLE = "{{env.AAA_FIRST}}/mid"
        \\AAA_FIRST = "/root"
    , "", &.{});
    try testing.expectEqualStrings("/root", res.env.get("AAA_FIRST").?);
    try testing.expectEqualStrings("/root/mid", res.env.get("MIDDLE").?);
    try testing.expectEqualStrings("/root/mid/deep", res.env.get("ZZZ_LAST").?);
}

test "a cycle is refused and the chain is named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var diag: Diagnostics = .{};
    var os_env: Env = .empty;
    const cfg = try config.parseBytes(a, "envee.toml",
        \\[env]
        \\A = "{{env.B}}"
        \\B = "{{env.A}}"
    , null);
    try testing.expectError(error.CycleDetected, apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, null, &diag));

    // Go сообщал цепочку из одного элемента, то есть не говорил, через что
    // замкнулся круг.
    try testing.expect(std.mem.indexOf(u8, diag.detail, "A") != null);
    try testing.expect(std.mem.indexOf(u8, diag.detail, "B") != null);
    try testing.expect(std.mem.indexOf(u8, diag.detail, "->") != null);
}

test "a self-referencing variable is a cycle too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var os_env: Env = .empty;
    const cfg = try config.parseBytes(a, "envee.toml", "[env]\nA = \"{{env.A}}\"\n", null);
    try testing.expectError(error.CycleDetected, apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, null, null));
}

test "profiles: only the active one is applied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const src =
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\
        \\[profiles.dev]
        \\DATABASE_URL = "postgres://localhost/dev"
        \\
        \\[profiles.prod]
        \\DATABASE_URL = "postgres://prod/db"
        \\LOG_LEVEL = "warn"
    ;
    const dev = try run(a, tmp, src, "dev", &.{});
    try testing.expectEqualStrings("postgres://localhost/dev", dev.env.get("DATABASE_URL").?);
    try testing.expect(dev.env.get("LOG_LEVEL") == null);

    const prod = try run(a, tmp, src, "prod", &.{});
    try testing.expectEqualStrings("postgres://prod/db", prod.env.get("DATABASE_URL").?);
    try testing.expectEqualStrings("warn", prod.env.get("LOG_LEVEL").?);

    // Без активного профиля не применяется ни один.
    const none = try run(a, tmp, src, "", &.{});
    try testing.expect(none.env.get("DATABASE_URL") == null);
    try testing.expectEqualStrings("myapp", none.env.get("SERVICE_NAME").?);
}

// Главная поправка к Go: `required` проверяется ПОСЛЕ того, как все
// источники значений отработали. Раньше проверка стояла до применения
// переменных самого профиля, и объявление ломалось о собственную же
// переменную. На этом падал поставляемый examples/multi-profile.
test "required is satisfied by the profile's own variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\BASE = "x"
        \\
        \\[profiles.prod]
        \\required = ["DATABASE_URL", "BASE"]
        \\
        \\[profiles.prod.env]
        \\DATABASE_URL = "postgres://prod/db"
    , "prod", &.{});
    try testing.expectEqualStrings("postgres://prod/db", res.env.get("DATABASE_URL").?);
}

test "required is satisfied by a file and by the env table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, ".env", "FROM_FILE=yes\n");

    const res = try run(a, tmp,
        \\[env]
        \\_.file = ".env"
        \\FROM_TOML = "yes"
        \\
        \\[profiles.prod]
        \\required = ["FROM_FILE", "FROM_TOML"]
    , "prod", &.{});
    try testing.expectEqualStrings("yes", res.env.get("FROM_FILE").?);
}

test "a genuinely missing required variable is still an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var os_env: Env = .empty;
    var diag: Diagnostics = .{};
    const cfg = try config.parseBytes(a, "envee.toml",
        \\[profiles.prod]
        \\required = ["NOWHERE"]
        \\[profiles.prod.env]
        \\OTHER = "1"
    , null);
    try testing.expectError(error.RequiredVarMissing, apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .profile = "prod",
        .os_env = &os_env,
    }, null, &diag));

    try testing.expectEqualStrings("NOWHERE", diag.key);
    // Go подставлял сюда литерал "?" вместо имени профиля.
    try testing.expectEqualStrings("prod", diag.profile);
}

test "the secret shorthand becomes a redacted placeholder without a plugin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\DATABASE_PASSWORD = { source = "env", ref = "DB_PASS", redact = true, required = true }
    , "", &.{});

    const entry = res.env.getEntry("DATABASE_PASSWORD").?;
    try testing.expect(entry.redacted);
    try testing.expectEqualStrings("__UNRESOLVED__:env:DB_PASS", entry.value);
    try testing.expectEqualStrings("secret:unresolved", entry.source);
}

test "the secret table form is resolved through a plugin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const Fake = struct {
        fn resolve(_: *anyopaque, _: Allocator, source: []const u8, ref: []const u8) anyerror![]const u8 {
            if (std.mem.eql(u8, source, "vault") and std.mem.eql(u8, ref, "good")) return "hunter2";
            return error.NotFound;
        }
    };
    var dummy: u8 = 0;
    const resolver: PluginResolver = .{ .ctx = &dummy, .resolveFn = Fake.resolve };

    var os_env: Env = .empty;
    const cfg = try config.parseBytes(a, "envee.toml",
        \\[env._.secret.DB]
        \\source = "vault"
        \\ref = "good"
        \\redact = true
    , null);
    const res = try apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, resolver, null);

    try testing.expectEqualStrings("hunter2", res.env.get("DB").?);
    try testing.expect(res.env.getEntry("DB").?.redacted);
    try testing.expectEqualStrings("secret:vault", res.env.getEntry("DB").?.source);
}

// Плагин может быть просто не настроен, и необязательный секрет не повод
// ломать всю оболочку. Обязательный — повод.
test "a failing secret is fatal only when it is required" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const Fake = struct {
        fn resolve(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]const u8 {
            return error.AuthRequired;
        }
    };
    var dummy: u8 = 0;
    const resolver: PluginResolver = .{ .ctx = &dummy, .resolveFn = Fake.resolve };
    var os_env: Env = .empty;

    const optional = try config.parseBytes(a, "envee.toml",
        \\[env._.secret.DB]
        \\source = "vault"
        \\ref = "x"
    , null);
    const res = try apply(a, std.testing.io, optional, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, resolver, null);
    try testing.expect(res.env.get("DB") == null);

    const required = try config.parseBytes(a, "envee.toml",
        \\[env._.secret.DB]
        \\source = "vault"
        \\ref = "x"
        \\required = true
    , null);
    var diag: Diagnostics = .{};
    try testing.expectError(error.SecretFailed, apply(a, std.testing.io, required, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, resolver, &diag));
    try testing.expectEqualStrings("DB", diag.key);
}

test "a shorthand secret without a ref is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var os_env: Env = .empty;
    var diag: Diagnostics = .{};
    const cfg = try config.parseBytes(a, "envee.toml",
        \\[env]
        \\DB = { source = "vault" }
    , null);
    try testing.expectError(error.SecretMissingRef, apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, null, &diag));
    try testing.expectEqualStrings("DB", diag.key);
}

// envee выгружает результат прямо в оболочку. Разреши конфигу задавать
// ENVEE_*, и он настраивал бы сам envee для всех остальных каталогов сессии.
test "a config may not set envee's own variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    var os_env: Env = .empty;
    var diag: Diagnostics = .{};
    const cfg = try config.parseBytes(a, "envee.toml", "[env]\nENVEE_PROFILE = \"sneaky\"\n", null);
    try testing.expectError(error.ReservedKey, apply(a, std.testing.io, cfg, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, null, &diag));
    try testing.expectEqualStrings("ENVEE_PROFILE", diag.key);

    // Проверка покрывает и переменные, пришедшие из файла.
    try tmp.write(a, ".env", "ENVEE_LOG=debug\n");
    const from_file = try config.parseBytes(a, "envee.toml", "[env]\n_.file = \".env\"\n", null);
    try testing.expectError(error.ReservedKey, apply(a, std.testing.io, from_file, .{
        .config_root = tmp.path,
        .os_env = &os_env,
    }, null, null));
}

test "meta keys never become variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\schema = "envee/v1"
        \\profile = "dev"
        \\[env]
        \\A = "1"
        \\watch = ["x"]
    , "", &.{});
    try testing.expectEqual(@as(usize, 1), res.env.len());
    try testing.expect(res.env.get("watch") == null);
    try testing.expect(res.env.get("schema") == null);
}

test "redactedKeys lists exactly the marked variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const res = try run(a, tmp,
        \\[env]
        \\PLAIN = "v"
        \\SECRET = { value = "s", redact = true }
    , "", &.{});
    const keys = try res.redactedKeys(a);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("SECRET", keys[0]);
}

test "prependToPath keeps order and drops duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "/a:/b:/usr/bin:/bin",
        try prependToPath(a, &.{ "/a", "/b" }, "/usr/bin:/bin"),
    );
    // Каталог, уже присутствующий в PATH, повторно не добавляется.
    try testing.expectEqualStrings(
        "/a:/usr/bin:/bin",
        try prependToPath(a, &.{ "/a", "/usr/bin" }, "/usr/bin:/bin"),
    );
    // Дубликаты внутри самого списка тоже схлопываются.
    try testing.expectEqualStrings(
        "/a:/usr/bin",
        try prependToPath(a, &.{ "/a", "/a" }, "/usr/bin"),
    );
    try testing.expectEqualStrings("/usr/bin", try prependToPath(a, &.{}, "/usr/bin"));
    try testing.expectEqualStrings("/a", try prependToPath(a, &.{"/a"}, ""));
}
