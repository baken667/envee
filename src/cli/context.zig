//! Общий контекст команд и то, что нужно нескольким из них сразу.
//!
//! Здесь живут `Ctx`, проверка доверия и путь «найти конфиг → проверить
//! доверие → применить директивы», которым пользуются `eval`, `resolve`,
//! `diff` и `status`. Вынесено из root.zig, чтобы файлы команд могли
//! импортировать это без кольцевой зависимости.
//!
//! Владение: всё выделяется из арены `Ctx`, живущей столько же, сколько
//! процесс.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const config = @import("../config.zig");
const directive = @import("../directive.zig");
const env_mod = @import("../env.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const paths_mod = @import("../paths.zig");
const plugin = @import("../plugin.zig");
const resolver_mod = @import("../resolver.zig");
const shell = @import("../shell/shell.zig");

/// Проверка доверия к конфигу.
///
/// Вынесена в отдельный тип, потому что настоящая реализация появится на
/// шаге 17 вместе с хранилищем, а тестам команд нужен работающий проход уже
/// сейчас. Заодно это единственная дверь, через которую конфиг попадает в
/// оболочку, — случайно обойти её нельзя.
pub const TrustGate = struct {
    ctx: *anyopaque,
    checkFn: *const fn (ctx: *anyopaque, sources: []const config.SourceFile) errs.Error!void,

    pub fn check(g: TrustGate, sources: []const config.SourceFile) errs.Error!void {
        return g.checkFn(g.ctx, sources);
    }

    /// Пока хранилища нет, ни один конфиг не одобрен. Ровно так ведёт себя и
    /// Go-версия с пустым хранилищем: конфиг применяется только после явного
    /// `envee trust`.
    pub fn denyAll() TrustGate {
        return .{ .ctx = undefined, .checkFn = denyAllCheck };
    }

    fn denyAllCheck(_: *anyopaque, sources: []const config.SourceFile) errs.Error!void {
        if (sources.len == 0) return;
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{
            .{ .key = "path", .value = sources[0].path },
            .{ .key = "hash", .value = sources[0].hash },
        };
        return errs.fail(.{
            .code = .e001,
            .summary = "envee.toml is not trusted",
            .context = &S.kv,
            .hint = "Run `envee trust` to review and approve its content.",
        }, error.TrustRequired);
    }

    /// Пропускает всё. Только для тестов команд: настоящее решение
    /// принимает хранилище.
    pub fn allowAll() TrustGate {
        const S = struct {
            fn check(_: *anyopaque, _: []const config.SourceFile) errs.Error!void {}
        };
        return .{ .ctx = undefined, .checkFn = S.check };
    }
};

pub const Ctx = struct {
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// Окружение процесса как отсортированная карта.
    os_env: env_mod.Map,
    paths: paths_mod.Paths,
    /// Рабочий каталог. Поле, а не вызов на месте: тесты подставляют сюда
    /// временный каталог, потому что рабочий каталог процесса менять нельзя.
    cwd: []const u8,
    stdout: *Writer,
    stderr: *Writer,
    /// Абсолютный путь к самому бинарю — попадает в сгенерированный hook.
    self_path: []const u8,
    /// Версия, попадающая в записи хранилища доверия.
    tool_version: []const u8 = "",
    trust: TrustGate,
};

pub const Error = errs.Error || errs.FailError || resolver_mod.Error || directive.Error ||
    Writer.Error || std.process.CurrentPathAllocError;

/// Конфиг вместе с тем, что понадобится дальше.
pub const Loaded = struct {
    cfg: config.Config,
    /// Каталог, в котором лежит первый конфиг.
    config_root: []const u8,
    /// Профиль, который в итоге применён.
    profile: []const u8,
};

/// Профиль: флаг важнее переменной окружения, та важнее значения из конфига.
pub fn activeProfile(ctx: *Ctx, flag: []const u8) []const u8 {
    if (flag.len > 0) return flag;
    return ctx.environ.get("ENVEE_PROFILE") orelse "";
}

/// Находит и разбирает конфиги для текущего каталога.
pub fn loadConfig(ctx: *Ctx, profile: []const u8, stop_at: []const u8) Error!Loaded {
    var r = resolver_mod.Resolver.init(ctx.cwd, ctx.paths);
    r.profile = profile;
    r.stop_at_root = stop_at;

    var diag: resolver_mod.Diagnostics = .{};
    const cfg = r.loadAll(ctx.arena, ctx.io, &diag) catch |err| return liftResolverError(err, diag);

    return .{
        .cfg = cfg,
        .config_root = gopath.dirname(ctx.arena, cfg.path) catch cfg.path,
        .profile = if (profile.len > 0) profile else cfg.profile,
    };
}

fn liftResolverError(err: anyerror, diag: resolver_mod.Diagnostics) Error {
    switch (err) {
        error.NoConfigFound => {
            const S = struct {
                var kv: [1]errs.KV = undefined;
            };
            S.kv = .{.{ .key = "searched_from", .value = diag.searched_from }};
            return errs.fail(.{
                .code = .e012,
                .summary = "no envee.toml found",
                .context = &S.kv,
                .hint = "Create an envee.toml in this directory or a parent.",
            }, error.FileNotFound);
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Место ошибки обязано попасть в сообщение: Go на этом месте
            // оставлял TODO и печатал только «failed to parse».
            const S = struct {
                var kv: [4]errs.KV = undefined;
                var line_buf: [24]u8 = undefined;
                var col_buf: [24]u8 = undefined;
            };
            S.kv = .{
                .{ .key = "path", .value = diag.path },
                .{ .key = "line", .value = std.fmt.bufPrint(&S.line_buf, "{d}", .{diag.parse.line}) catch "?" },
                .{ .key = "column", .value = std.fmt.bufPrint(&S.col_buf, "{d}", .{diag.parse.column}) catch "?" },
                .{ .key = "detail", .value = if (diag.parse.detail.len > 0) diag.parse.detail else @errorName(err) },
            };
            return errs.fail(.{
                .code = .e002,
                .summary = "failed to parse envee.toml",
                .context = &S.kv,
                .hint = "Check TOML syntax at the indicated line.",
            }, error.ConfigParse);
        },
    }
}

/// Полный путь: найти конфиг, проверить доверие, применить директивы.
///
/// Проверка доверия стоит ПЕРЕД применением, а не после: директивы умеют
/// вызывать плагины секретов и читать файлы, то есть у них есть побочные
/// эффекты, и неодобренному конфигу их устраивать нельзя.
pub fn resolveEnv(ctx: *Ctx, profile_flag: []const u8, stop_at: []const u8) Error!struct {
    loaded: Loaded,
    result: directive.Result,
} {
    const loaded = try loadConfig(ctx, activeProfile(ctx, profile_flag), stop_at);
    try ctx.trust.check(loaded.cfg.sources);

    // Плагины ищутся только если конфиг объявляет секреты — и только после
    // проверки доверия выше: обнаружение запускает чужие бинари.
    var dispatcher = try plugin.dispatcherFor(ctx.arena, ctx.io, ctx.environ, loaded.cfg);
    const resolver: ?directive.PluginResolver = if (dispatcher) |*d| d.resolver() else null;

    var diag: directive.Diagnostics = .{};
    const result = directive.apply(ctx.arena, ctx.io, loaded.cfg, .{
        .config_root = loaded.config_root,
        .profile = loaded.profile,
        .cwd = ctx.cwd,
        .os_env = &ctx.os_env,
    }, resolver, &diag) catch |err| return liftDirectiveError(err, diag);

    return .{ .loaded = loaded, .result = result };
}

/// Превращает ошибку применения директив в диагностику с кодом.
///
/// Без этого пользователь видел бы голое имя ошибки вместо объяснения,
/// подсказки и ссылки на документацию — то есть ровно ничего полезного.
fn liftDirectiveError(err: anyerror, diag: directive.Diagnostics) Error {
    const S = struct {
        var kv: [2]errs.KV = undefined;
    };
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RequiredVarMissing => {
            var n: usize = 1;
            S.kv[0] = .{ .key = "variable", .value = diag.key };
            if (diag.profile.len > 0) {
                S.kv[1] = .{ .key = "profile", .value = diag.profile };
                n = 2;
            }
            return errs.fail(.{
                .code = .e008,
                .summary = "required variable not defined",
                .context = S.kv[0..n],
                .hint = "Set it in envee.toml, .env file, or via a secret plugin.",
            }, error.RequiredVarMissing);
        },
        error.CycleDetected => {
            S.kv[0] = .{ .key = "chain", .value = diag.detail };
            return errs.fail(.{
                .code = .e007,
                .summary = "circular dependency in template",
                .context = S.kv[0..1],
                .hint = "Break the cycle by using a constant value.",
            }, error.CycleDetected);
        },
        error.ReservedKey => {
            S.kv[0] = .{ .key = "key", .value = diag.key };
            return errs.fail(.{
                .code = .e003,
                .summary = "config may not set reserved variable",
                .context = S.kv[0..1],
                .hint = "Variables starting with ENVEE_ configure envee itself and cannot be set from a config file.",
            }, error.ConfigValidation);
        },
        error.SecretMissingRef => {
            S.kv[0] = .{ .key = "key", .value = diag.key };
            return errs.fail(.{
                .code = .e003,
                .summary = "secret shorthand missing 'ref'",
                .context = S.kv[0..1],
            }, error.ConfigValidation);
        },
        error.SecretFailed => {
            S.kv[0] = .{ .key = "variable", .value = diag.key };
            S.kv[1] = .{ .key = "detail", .value = diag.detail };
            return errs.fail(.{
                .code = .e004,
                .summary = "secret plugin failed",
                .context = S.kv[0..2],
            }, error.PluginFailed);
        },
        error.RequiredFileMissing => {
            S.kv[0] = .{ .key = "path", .value = diag.file.path };
            return errs.fail(.{
                .code = .e012,
                .summary = "file not found",
                .context = S.kv[0..1],
                .hint = "Create the file or set `required = false` in the _.file directive.",
            }, error.FileNotFound);
        },
        error.UnsupportedFormat, error.MissingPath => {
            S.kv[0] = .{ .key = "path", .value = diag.file.path };
            S.kv[1] = .{ .key = "detail", .value = diag.file.detail };
            return errs.fail(.{
                .code = .e003,
                .summary = "unsupported _.file entry",
                .context = S.kv[0..2],
            }, error.ConfigValidation);
        },
        error.ParseFailed => {
            S.kv[0] = .{ .key = "path", .value = diag.file.path };
            S.kv[1] = .{ .key = "format", .value = diag.file.format };
            return errs.fail(.{
                .code = .e002,
                .summary = "parse failed",
                .context = S.kv[0..2],
            }, error.ConfigParse);
        },
        else => {
            S.kv[0] = .{ .key = "detail", .value = @errorName(err) };
            return errs.fail(.{
                .code = .e005,
                .summary = "failed to resolve the environment",
                .context = S.kv[0..1],
            }, error.TemplateFailed);
        },
    }
}

pub fn unsupportedShell(name: []const u8) Error {
    const S = struct {
        var kv: [1]errs.KV = undefined;
    };
    S.kv = .{.{ .key = "shell", .value = name }};
    return errs.fail(.{
        .code = .e003,
        .summary = "unsupported shell",
        .context = &S.kv,
        .hint = "Supported: bash, zsh, fish, nu, pwsh",
    }, error.ConfigValidation);
}

// ---- вывод изменений окружения ---------------------------------------------

/// Печатает разницу между текущим окружением и разрешённым.
///
/// ВНИМАНИЕ, отличие от Go-версии по ПОВЕДЕНИЮ. Go передавал в `setPath`
/// ПОЛНЫЙ новый `$PATH`, а адаптер дописывает к своему аргументу ещё и
/// `:"$PATH"` — текущий PATH попадал в результат дважды. Проверено на
/// выпущенной версии: из PATH в две записи получалось семь вместо пяти, с
/// дублями. Сюда передаются ТОЛЬКО новые каталоги, как и предполагает
/// контракт адаптера (и его собственные тесты).
pub fn writeShellDiff(
    ctx: *Ctx,
    w: *Writer,
    adapter: shell.Adapter,
    result: directive.Result,
) Error!void {
    const current_path = ctx.os_env.get("PATH") orelse "";
    const new_dirs = try newPathDirs(ctx.arena, result.path_prepend, current_path);

    if (adapter.supportsDiffRender()) {
        // Оболочки без eval получают весь diff одним куском, и PATH там —
        // обычное присваивание, поэтому нужен полный путь.
        var set: std.ArrayList(shell.KV) = .empty;
        if (new_dirs.len > 0) {
            const full = try directive.prependToPath(ctx.arena, new_dirs, current_path);
            try set.append(ctx.arena, .{ .key = "PATH", .value = full });
        }
        for (result.env.entries.items) |e| {
            if (std.mem.eql(u8, e.key, "PATH") or e.key.len == 0) continue;
            if (ctx.os_env.get(e.key)) |old| {
                if (std.mem.eql(u8, old, e.value)) continue;
            }
            try set.append(ctx.arena, .{ .key = e.key, .value = e.value });
        }
        return adapter.writeDiff(ctx.arena, w, set.items, &.{});
    }

    if (new_dirs.len > 0) {
        try adapter.writeSetPath(w, new_dirs);
        try w.writeByte('\n');
    }
    // Переменные идут отсортированными: вывод обязан быть одинаковым от
    // запуска к запуску, иначе hook нельзя ни сравнить, ни закешировать.
    for (result.env.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "PATH") or e.key.len == 0) continue;
        if (ctx.os_env.get(e.key)) |old| {
            if (std.mem.eql(u8, old, e.value)) continue;
        }
        var esc: Writer.Allocating = .init(ctx.arena);
        try adapter.writeEscaped(&esc.writer, e.value);
        try adapter.writeExport(w, e.key, esc.written());
        try w.writeByte('\n');
    }
}

/// Каталоги, которых ещё нет в $PATH, в порядке объявления.
pub fn newPathDirs(
    arena: Allocator,
    prepend: []const []const u8,
    current: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);

    var it = std.mem.splitScalar(u8, current, ':');
    while (it.next()) |d| try seen.put(arena, d, {});

    for (prepend) |d| {
        if (seen.contains(d)) continue;
        try seen.put(arena, d, {});
        try out.append(arena, d);
    }
    return out.toOwnedSlice(arena);
}
