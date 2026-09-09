//! Дерево команд envee и их выполнение.
//!
//! Порт `internal/cli/root.go`, `init.go`, `eval.go`, `deps.go`,
//! `trustgate.go`.
//!
//! Реализованы `init`, `version` и `eval`. Остальные команды объявлены в
//! дереве, чтобы справка и подсказки были полными, и пока честно сообщают,
//! что не готовы, — это лучше, чем делать вид, что сработали.
//!
//! Владение: `Ctx` живёт столько же, сколько процесс; всё выделяется из его
//! арены.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const config = @import("../config.zig");
const directive = @import("../directive.zig");
const env_mod = @import("../env.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const log = @import("../log.zig");
const paths_mod = @import("../paths.zig");
const resolver_mod = @import("../resolver.zig");
const shell = @import("../shell/shell.zig");

pub const build_options = @import("build_options");

/// Проверка доверия к конфигу.
///
/// Вынесена в отдельный тип, потому что настоящая реализация появится на
/// шаге 17 вместе с хранилищем, а тестам `eval` нужен работающий проход уже
/// сейчас. Заодно это единственное место, через которое `eval` может решить
/// применить конфиг, — случайно обойти его нельзя.
pub const TrustGate = struct {
    ctx: *anyopaque,
    checkFn: *const fn (ctx: *anyopaque, sources: []const config.SourceFile) errs.Error!void,

    pub fn check(g: TrustGate, sources: []const config.SourceFile) errs.Error!void {
        return g.checkFn(g.ctx, sources);
    }

    /// Пока хранилища нет, ни один конфиг не одобрен. Ровно так ведёт себя
    /// и Go-версия с пустым хранилищем: конфиг применяется только после
    /// явного `envee trust`.
    pub fn denyAll() TrustGate {
        return .{ .ctx = undefined, .checkFn = denyAllCheck };
    }

    fn denyAllCheck(_: *anyopaque, sources: []const config.SourceFile) errs.Error!void {
        if (sources.len == 0) return;
        var ctx: [2]errs.KV = undefined;
        ctx = .{
            .{ .key = "path", .value = sources[0].path },
            .{ .key = "hash", .value = sources[0].hash },
        };
        return errs.fail(.{
            .code = .e001,
            .summary = "envee.toml is not trusted",
            .context = &ctx,
            .hint = "Run `envee trust` to review and approve its content.",
        }, error.TrustRequired);
    }
};

pub const Ctx = struct {
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// Окружение процесса как отсортированная карта.
    os_env: env_mod.Map,
    paths: paths_mod.Paths,
    stdout: *Writer,
    stderr: *Writer,
    /// Абсолютный путь к самому бинарю — попадает в сгенерированный hook.
    self_path: []const u8,
    trust: TrustGate,
};

// ---- дерево команд ---------------------------------------------------------

const persistent_flags = [_]args_mod.Flag{
    .{ .long = "config", .kind = .{ .string = "" }, .help = "path to envee.toml (default: auto-discover)", .persistent = true },
    .{ .long = "profile", .kind = .{ .string = "" }, .help = "profile to use (overrides $ENVEE_PROFILE)", .persistent = true },
    .{ .long = "log-level", .kind = .{ .string = "warn" }, .help = "log level: trace|debug|info|warn|error", .persistent = true },
    .{ .long = "log-format", .kind = .{ .string = "text" }, .help = "log format: text|json", .persistent = true },
    .{ .long = "color", .kind = .{ .string = "auto" }, .help = "color mode: auto|always|never", .persistent = true },
    .{ .long = "quiet", .short = 'q', .help = "suppress non-essential output", .persistent = true },
    .{ .long = "verbose", .short = 'v', .kind = .counter, .help = "increase log verbosity (-v = info, -vv = debug)", .persistent = true },
    .{ .long = "debug", .help = "enable debug mode (stacktraces, more logs)", .persistent = true },
    .{ .long = "no-telemetry", .help = "disable telemetry for this invocation", .persistent = true },
};

pub const root: args_mod.Command = .{
    .name = "envee",
    .short = "Per-directory environment variable manager",
    .long =
    \\envee loads environment variables from envee.toml when you enter a directory.
    \\
    \\It is a fast, secure, declarative replacement for direnv. Unlike direnv,
    \\envee uses a structured TOML configuration (no shell scripts in your .envrc)
    \\and supports profiles, secret plugins, and an opt-in WASM script layer.
    \\
    \\Get started:
    \\  envee init bash >> ~/.bashrc   # add the shell hook
    \\  cd ~/work/myproj               # enter a project with envee.toml
    \\  envee trust                    # approve the project once
    \\  echo $DATABASE_URL             # env vars are now loaded
    ,
    .flags = &persistent_flags,
    .subcommands = &.{
        .{
            .name = "check",
            .usage_args = "[path]",
            .short = "Static analysis of envee.toml",
            .args = .any,
        },
        .{
            .name = "completion",
            .usage_args = "<shell>",
            .short = "Generate shell completion script",
            .args = .{ .exact = 1 },
        },
        .{
            .name = "daemon",
            .short = "Manage the enveed background daemon",
            .subcommands = &.{
                .{ .name = "status", .short = "Check whether enveed is running" },
                .{ .name = "start", .short = "Start the daemon", .hidden = true },
                .{ .name = "stop", .short = "Stop the daemon", .hidden = true },
            },
        },
        .{ .name = "deny", .usage_args = "[path]", .short = "Deny envee.toml (explicit block)", .args = .any },
        .{ .name = "diff", .usage_args = "<shell>", .short = "Show env changes since last eval", .args = .{ .exact = 1 } },
        .{ .name = "doctor", .short = "Run health diagnostics" },
        .{
            .name = "eval",
            .usage_args = "<shell>",
            .short = "Print shell-specific export/unset commands",
            .long =
            \\Output the env diff (vs the current shell) as commands the target shell
            \\can eval. Used by the shell hook on every prompt.
            \\
            \\Supports: bash, zsh, fish, nu, pwsh.
            \\
            \\Example:
            \\  eval "$(envee eval bash)"
            ,
            .args = .{ .exact = 1 },
        },
        .{
            .name = "exec",
            .usage_args = "-- <command> [args...]",
            .short = "Run a command with the loaded env (no shell hook needed)",
            .args = .passthrough,
        },
        .{
            .name = "init",
            .usage_args = "<shell>",
            .short = "Generate shell hook code",
            .long =
            \\Output shell-specific hook code to be eval'd at shell startup.
            \\
            \\Supported shells: bash, zsh, fish, nu, pwsh.
            \\
            \\Add to your shell config:
            \\  bash:  eval "$(envee init bash)"
            \\  zsh:   eval "$(envee init zsh)"
            \\  fish:  envee init fish | source
            ,
            .args = .{ .exact = 1 },
            .flags = &.{
                .{ .long = "cached", .help = "write to cache file instead of stdout" },
            },
        },
        .{
            .name = "plugin",
            .short = "Manage plugins",
            .subcommands = &.{
                .{ .name = "list", .short = "List discovered plugins" },
                .{ .name = "info", .usage_args = "<name>", .short = "Show plugin metadata", .args = .{ .exact = 1 } },
                .{ .name = "install", .usage_args = "<name>", .short = "Install a plugin", .args = .{ .exact = 1 }, .hidden = true },
            },
        },
        .{ .name = "resolve", .short = "Compute and print the resolved environment", .flags = &.{
            .{ .long = "json", .help = "output as JSON" },
        } },
        .{
            .name = "secret",
            .short = "Manage secrets in the local env store (used by envee-plugin-env)",
            .subcommands = &.{
                .{ .name = "set", .usage_args = "KEY=VALUE", .short = "Set a secret", .args = .{ .exact = 1 } },
                .{ .name = "unset", .usage_args = "KEY", .short = "Remove a secret", .args = .{ .exact = 1 } },
                .{ .name = "list", .short = "List stored secret names" },
                .{ .name = "get", .usage_args = "KEY", .short = "Print one secret", .args = .{ .exact = 1 } },
            },
        },
        .{ .name = "status", .short = "Show current envee state", .flags = &.{
            .{ .long = "trust", .help = "show trust entries" },
        } },
        .{
            .name = "trust",
            .usage_args = "[path]",
            .short = "Trust envee.toml (review and approve its content)",
            .args = .any,
            .flags = &.{
                .{ .long = "yes", .short = 'y', .help = "approve without prompting" },
                .{ .long = "ttl", .kind = .{ .string = "" }, .help = "expire the approval after this duration" },
            },
        },
        .{ .name = "version", .short = "Show envee version" },
        // Объявлено, но не реализовано. Скрыто из справки: обещать команду,
        // которой нет, хуже, чем не показывать её.
        .{ .name = "debug", .short = "Dump internal state", .hidden = true },
        .{ .name = "telemetry", .short = "Toggle telemetry", .hidden = true },
        .{ .name = "upgrade", .short = "Upgrade envee in place", .hidden = true },
    },
};

// ---- выполнение ------------------------------------------------------------

pub const Error = errs.Error || errs.FailError || resolver_mod.Error || directive.Error ||
    args_mod.Error || Writer.Error || std.process.CurrentPathAllocError;

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const name = parsed.command.name;
    if (std.mem.eql(u8, name, "version")) return runVersion(ctx);
    if (std.mem.eql(u8, name, "init")) return runInit(ctx, parsed);
    if (std.mem.eql(u8, name, "eval")) return runEval(ctx, parsed);
    return notImplemented(ctx, parsed);
}

fn notImplemented(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const full = try parsed.commandPath(ctx.arena);
    try ctx.stderr.print("Error: `{s}` is not implemented yet\n", .{full});
    return error.VersionIncompatible;
}

pub fn versionString(gpa: Allocator) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s} (commit {s}, built {s}, zig {s})", .{
        build_options.version,
        build_options.commit,
        build_options.date,
        build_options.zig_version,
    });
}

fn runVersion(ctx: *Ctx) Error!void {
    try ctx.stdout.print("envee version {s}\n", .{try versionString(ctx.arena)});
}

fn runInit(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse return unsupportedShell(ctx, parsed.args[0]);
    try adapter.writeInit(ctx.stdout, ctx.self_path);
}

fn unsupportedShell(_: *Ctx, name: []const u8) Error {
    var ctx_kv: [1]errs.KV = .{.{ .key = "shell", .value = name }};
    return errs.fail(.{
        .code = .e003,
        .summary = "unsupported shell",
        .context = &ctx_kv,
        .hint = "Supported: bash, zsh, fish, nu, pwsh",
    }, error.ConfigValidation);
}

/// `envee eval <shell>` — то, что вызывает hook на каждом приглашении.
fn runEval(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse return unsupportedShell(ctx, parsed.args[0]);

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.arena);

    // Профиль: флаг важнее переменной окружения.
    var profile = parsed.str("profile");
    if (profile.len == 0) profile = ctx.environ.get("ENVEE_PROFILE") orelse "";

    var r = resolver_mod.Resolver.init(cwd, ctx.paths);
    r.profile = profile;

    var res_diag: resolver_mod.Diagnostics = .{};
    const cfg = try loadConfig(ctx, r, &res_diag);

    // Проверка доверия идёт по КАЖДОМУ файлу, вложившемуся в конфиг, а не
    // только по первому: envee.local.toml и envee.d/ иначе применялись бы
    // без одобрения.
    try ctx.trust.check(cfg.sources);

    const active_profile = if (profile.len > 0) profile else cfg.profile;
    const config_root = gopath.dirname(ctx.arena, cfg.path) catch cfg.path;

    const result = try directive.apply(ctx.arena, ctx.io, cfg, .{
        .config_root = config_root,
        .profile = active_profile,
        .cwd = cwd,
        .os_env = &ctx.os_env,
    }, null, null);

    try writeShellDiff(ctx, adapter, result);

    // Список зависимостей позволяет hook'у на следующем приглашении вообще
    // не запускать envee.
    if (adapter.supportsFastPath()) {
        try adapter.writeFastPath(ctx.stdout, try evalDeps(ctx.arena, cfg, cwd, config_root));
    }
}

fn loadConfig(ctx: *Ctx, r: resolver_mod.Resolver, diag: *resolver_mod.Diagnostics) Error!config.Config {
    return r.loadAll(ctx.arena, ctx.io, diag) catch |err| switch (err) {
        error.NoConfigFound => {
            var kv: [1]errs.KV = .{.{ .key = "searched_from", .value = diag.searched_from }};
            return errs.fail(.{
                .code = .e012,
                .summary = "no envee.toml found",
                .context = &kv,
                .hint = "Create an envee.toml in this directory or a parent.",
            }, error.FileNotFound);
        },
        error.OutOfMemory => error.OutOfMemory,
        else => {
            var line_buf: [24]u8 = undefined;
            var col_buf: [24]u8 = undefined;
            var kv: [4]errs.KV = .{
                .{ .key = "path", .value = diag.path },
                .{ .key = "line", .value = std.fmt.bufPrint(&line_buf, "{d}", .{diag.parse.line}) catch "?" },
                .{ .key = "column", .value = std.fmt.bufPrint(&col_buf, "{d}", .{diag.parse.column}) catch "?" },
                .{ .key = "detail", .value = if (diag.parse.detail.len > 0) diag.parse.detail else @errorName(err) },
            };
            return errs.fail(.{
                .code = .e002,
                .summary = "failed to parse envee.toml",
                .context = &kv,
                .hint = "Check TOML syntax at the indicated line.",
            }, error.ConfigParse);
        },
    };
}

/// Печатает разницу между текущим окружением и разрешённым.
///
/// ВНИМАНИЕ, отличие от Go-версии по ПОВЕДЕНИЮ. Go передавал в `setPath`
/// ПОЛНЫЙ новый $PATH, а адаптер дописывает к своему аргументу ещё и
/// `:"$PATH"` — то есть текущий PATH попадал в результат дважды. Проверено
/// на выпущенной версии: из PATH в две записи получалось семь вместо пяти,
/// с дублями `/usr/bin` и `/bin`. Сюда передаются ТОЛЬКО новые каталоги, как
/// и предполагает контракт адаптера (и его собственные тесты).
fn writeShellDiff(ctx: *Ctx, adapter: shell.Adapter, result: directive.Result) Error!void {
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
            const old = ctx.os_env.get(e.key);
            if (old != null and std.mem.eql(u8, old.?, e.value)) continue;
            try set.append(ctx.arena, .{ .key = e.key, .value = e.value });
        }
        return adapter.writeDiff(ctx.arena, ctx.stdout, set.items, &.{});
    }

    if (new_dirs.len > 0) {
        try adapter.writeSetPath(ctx.stdout, new_dirs);
        try ctx.stdout.writeByte('\n');
    }
    // Переменные идут отсортированными: вывод обязан быть одинаковым от
    // запуска к запуску, иначе hook нельзя ни сравнить, ни закешировать.
    for (result.env.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "PATH") or e.key.len == 0) continue;
        const old = ctx.os_env.get(e.key);
        if (old != null and std.mem.eql(u8, old.?, e.value)) continue;

        var esc: Writer.Allocating = .init(ctx.arena);
        try adapter.writeEscaped(&esc.writer, e.value);
        try adapter.writeExport(ctx.stdout, e.key, esc.written());
        try ctx.stdout.writeByte('\n');
    }
}

/// Каталоги, которых ещё нет в $PATH, в порядке объявления.
fn newPathDirs(
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

/// Файлы и каталоги, от которых зависит результат.
///
/// В список входят: рабочий каталог, каждый вложившийся конфиг и его
/// каталог, файлы из `_.file` и `_.source`, пути из `watch`. Каталоги важны
/// не меньше файлов: несуществующий файл не с чем сравнивать по времени, а
/// удалённый перестаёт существовать, но в обоих случаях меняется время
/// каталога. Это покрывает появление нового `envee.toml` рядом и удаление
/// `.env`.
///
/// Сознательно НЕ покрыто: появление конфига в родительском каталоге, где
/// его не было. Следить за всеми предками значит следить за домашним
/// каталогом и пересчитывать окружение на каждое постороннее изменение в
/// нём. У direnv та же граница; конфиг подхватится при следующей смене
/// каталога.
fn evalDeps(
    arena: Allocator,
    cfg: config.Config,
    cwd: []const u8,
    config_root: []const u8,
) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);

    const add = struct {
        fn f(
            a: Allocator,
            list: *std.ArrayList([]const u8),
            known: *std.StringArrayHashMapUnmanaged(void),
            p: []const u8,
        ) Allocator.Error!void {
            if (p.len == 0 or !std.fs.path.isAbsolute(p)) return;
            if (known.contains(p)) return;
            try known.put(a, p, {});
            try list.append(a, p);
        }
    }.f;

    try add(arena, &out, &seen, cwd);
    for (cfg.sources) |src| {
        try add(arena, &out, &seen, src.path);
        if (std.fs.path.dirname(src.path)) |dir| try add(arena, &out, &seen, dir);
    }

    const resolve = struct {
        fn f(a: Allocator, root_dir: []const u8, p: []const u8) Allocator.Error![]const u8 {
            if (p.len == 0 or std.fs.path.isAbsolute(p)) return p;
            return gopath.join(a, &.{ root_dir, p });
        }
    }.f;

    for (cfg.directives.file) |ref| try add(arena, &out, &seen, try resolve(arena, config_root, ref.path));
    for (cfg.directives.source) |ref| try add(arena, &out, &seen, try resolve(arena, config_root, ref.path));
    for (cfg.watched_paths) |w| try add(arena, &out, &seen, try resolve(arena, config_root, w));

    // Порядок фиксирован, чтобы вывод eval не менялся от запуска к запуску.
    const items = try out.toOwnedSlice(arena);
    std.mem.sort([]const u8, @constCast(items), {}, lessThanSlice);
    return items;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Настраивает глобальный логгер по разобранным флагам.
pub fn configureLogging(parsed: args_mod.Parsed, out: *Writer) void {
    var level = log.Level.parse(parsed.str("log-level"));
    // -v поднимает подробность, -vv ещё сильнее. В Go этот флаг объявлен
    // булевым и читается как число, поэтому не делает ничего.
    switch (parsed.count("verbose")) {
        0 => {},
        1 => level = .info,
        2 => level = .debug,
        else => level = .trace,
    }
    if (parsed.boolean("debug")) level = .debug;

    log.configure(out, .{
        .level = level,
        .format = log.Format.parse(parsed.str("log-format")),
        .quiet = parsed.boolean("quiet"),
    });
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Гейт, пропускающий всё: настоящее хранилище появится на шаге 17, а
/// проверять `eval` надо уже сейчас.
fn allowAllGate() TrustGate {
    const S = struct {
        fn check(_: *anyopaque, _: []const config.SourceFile) errs.Error!void {}
    };
    return .{ .ctx = undefined, .checkFn = S.check };
}

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

/// Выполняет команду в подготовленном каталоге и возвращает stdout.
///
/// Рабочий каталог процесса менять нельзя (тесты идут параллельно), поэтому
/// eval проверяется через прямой вызов внутренностей с подставленным cwd.
fn runIn(
    gpa: Allocator,
    dir: TempDir,
    argv: []const []const u8,
    os_pairs: []const [2][]const u8,
) ![]const u8 {
    var environ: std.process.Environ.Map = .init(gpa);
    try environ.put("HOME", dir.path);
    for (os_pairs) |p| try environ.put(p[0], p[1]);

    var os_env: env_mod.Map = .empty;
    for (os_pairs) |p| try os_env.set(gpa, p[0], p[1]);

    var out: Writer.Allocating = .init(gpa);
    var err_out: Writer.Allocating = .init(gpa);

    var ctx: Ctx = .{
        .arena = gpa,
        .io = std.testing.io,
        .environ = &environ,
        .os_env = os_env,
        .paths = try paths_mod.Paths.init(gpa, &environ),
        .stdout = &out.writer,
        .stderr = &err_out.writer,
        .self_path = "/usr/local/bin/envee",
        .trust = allowAllGate(),
    };

    const parsed = try args_mod.parse(gpa, &root, argv, null);
    if (std.mem.eql(u8, parsed.command.name, "eval")) {
        try runEvalIn(&ctx, parsed, dir.path);
    } else {
        try run(&ctx, parsed);
    }
    return out.written();
}

/// Как runEval, но с явным рабочим каталогом.
fn runEvalIn(ctx: *Ctx, parsed: args_mod.Parsed, cwd: []const u8) Error!void {
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse return unsupportedShell(ctx, parsed.args[0]);

    var profile = parsed.str("profile");
    if (profile.len == 0) profile = ctx.environ.get("ENVEE_PROFILE") orelse "";

    var r = resolver_mod.Resolver.init(cwd, ctx.paths);
    r.profile = profile;
    r.stop_at_root = cwd;

    var res_diag: resolver_mod.Diagnostics = .{};
    const cfg = try loadConfig(ctx, r, &res_diag);
    try ctx.trust.check(cfg.sources);

    const active_profile = if (profile.len > 0) profile else cfg.profile;
    const config_root = gopath.dirname(ctx.arena, cfg.path) catch cfg.path;
    const result = try directive.apply(ctx.arena, ctx.io, cfg, .{
        .config_root = config_root,
        .profile = active_profile,
        .cwd = cwd,
        .os_env = &ctx.os_env,
    }, null, null);

    try writeShellDiff(ctx, adapter, result);
    if (adapter.supportsFastPath()) {
        try adapter.writeFastPath(ctx.stdout, try evalDeps(ctx.arena, cfg, cwd, config_root));
    }
}

test "version prints the build metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    const out = try runIn(a, tmp, &.{"version"}, &.{});
    try testing.expect(std.mem.startsWith(u8, out, "envee version "));
    try testing.expect(std.mem.indexOf(u8, out, "commit ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig ") != null);
}

test "init emits the hook for each shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    for ([_][]const u8{ "bash", "zsh", "fish", "nu", "pwsh" }) |sh| {
        const out = try runIn(a, tmp, &.{ "init", sh }, &.{});
        try testing.expect(out.len > 100);
        try testing.expect(std.mem.indexOf(u8, out, "/usr/local/bin/envee") != null);
        try testing.expect(std.mem.indexOf(u8, out, "{{.SelfPath}}") == null);
    }
}

test "init refuses an unsupported shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.ConfigValidation, runIn(a, tmp, &.{ "init", "tcsh" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e003, d.code);
    try testing.expectEqualStrings("tcsh", d.context[0].value);
}

test "eval exports variables for bash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml",
        \\schema = "envee/v1"
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\PORT = 5432
        \\SPACED = "a b"
    );

    const out = try runIn(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin:/bin" }});
    try testing.expect(std.mem.indexOf(u8, out, "export PORT=5432;\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "export SERVICE_NAME=myapp;\n") != null);
    // Значение с пробелом обязано приехать в кавычках.
    try testing.expect(std.mem.indexOf(u8, out, "export SPACED='a b';\n") != null);
    // Список зависимостей для быстрого пути.
    try testing.expect(std.mem.indexOf(u8, out, "__envee_deps=(") != null);
}

// Go передавал в setPath ПОЛНЫЙ новый PATH, а адаптер дописывал к нему ещё
// и текущий: из двух записей получалось семь вместо пяти, с дублями.
test "eval does not duplicate the existing PATH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "[env]\n_.path = [\"./bin\", \"./tools\"]\n");

    const out = try runIn(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin:/bin" }});

    const line_end = std.mem.indexOfScalar(u8, out, '\n').?;
    const path_line = out[0..line_end];
    try testing.expect(std.mem.startsWith(u8, path_line, "export PATH="));
    // Ровно два новых каталога плюс ссылка на текущий PATH — и ни одного
    // повторения /usr/bin или /bin.
    try testing.expect(std.mem.indexOf(u8, path_line, "/bin/bin") == null);
    try testing.expect(std.mem.indexOf(u8, path_line, "/usr/bin") == null);
    try testing.expect(std.mem.endsWith(u8, path_line, ":\"$PATH\";"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, path_line, tmp.path));
}

// Каталог, уже присутствующий в PATH, второй раз не добавляется — иначе
// PATH распухал бы на каждом приглашении.
test "eval skips a path entry already present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "[env]\n_.path = [\"./bin\"]\n");

    const bin = try gopath.join(a, &.{ tmp.path, "bin" });
    const already = try std.fmt.allocPrint(a, "{s}:/usr/bin", .{bin});
    const out = try runIn(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", already }});
    try testing.expect(std.mem.indexOf(u8, out, "export PATH=") == null);
}

test "eval skips variables that already hold the same value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "[env]\nSAME = \"v\"\nCHANGED = \"new\"\n");

    const out = try runIn(a, tmp, &.{ "eval", "bash" }, &.{
        .{ "PATH", "/usr/bin" },
        .{ "SAME", "v" },
        .{ "CHANGED", "old" },
    });
    try testing.expect(std.mem.indexOf(u8, out, "SAME") == null);
    try testing.expect(std.mem.indexOf(u8, out, "export CHANGED=new;") != null);
}

test "eval honours the profile from the flag and from the environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml",
        \\[profiles.dev.env]
        \\WHICH = "dev"
        \\[profiles.prod.env]
        \\WHICH = "prod"
    );

    const by_flag = try runIn(a, tmp, &.{ "--profile", "prod", "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }});
    try testing.expect(std.mem.indexOf(u8, by_flag, "export WHICH=prod;") != null);

    const by_env = try runIn(a, tmp, &.{ "eval", "bash" }, &.{
        .{ "PATH", "/usr/bin" },
        .{ "ENVEE_PROFILE", "dev" },
    });
    try testing.expect(std.mem.indexOf(u8, by_env, "export WHICH=dev;") != null);
}

test "eval renders JSON for nushell and shell code for the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "[env]\nA = \"1\"\n");

    const nu = try runIn(a, tmp, &.{ "eval", "nu" }, &.{.{ "PATH", "/usr/bin" }});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, nu, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("1", parsed.value.object.get("set").?.object.get("A").?.string);
    // У nushell нет быстрого пути, значит и списка зависимостей быть не должно.
    try testing.expect(std.mem.indexOf(u8, nu, "__envee_deps") == null);

    const fish = try runIn(a, tmp, &.{ "eval", "fish" }, &.{.{ "PATH", "/usr/bin" }});
    try testing.expect(std.mem.indexOf(u8, fish, "set -gx A '1'\n") != null);
    try testing.expect(std.mem.indexOf(u8, fish, "set -g __envee_deps") != null);
}

test "eval without a config reports where it looked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.FileNotFound, runIn(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e012, d.code);
    try testing.expectEqual(@as(u8, 4), d.exitCode());
}

test "a broken config reports the file and the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "schema = \"envee/v1\"\nbroken = = =\n");

    errs.reset();
    try testing.expectError(error.ConfigParse, runIn(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e002, d.code);
    // В контексте должны быть путь и номер строки: Go на этом месте
    // оставлял TODO и печатал только «failed to parse».
    try testing.expectEqualStrings("2", d.context[1].value);
}

// Гейт доверия — единственная дверь, через которую конфиг попадает в
// оболочку. По умолчанию она закрыта.
test "eval refuses an untrusted config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "envee.toml", "[env]\nA = \"1\"\n");

    var environ: std.process.Environ.Map = .init(a);
    try environ.put("HOME", tmp.path);
    const os_env: env_mod.Map = .empty;
    var out: Writer.Allocating = .init(a);
    var err_out: Writer.Allocating = .init(a);

    var ctx: Ctx = .{
        .arena = a,
        .io = std.testing.io,
        .environ = &environ,
        .os_env = os_env,
        .paths = try paths_mod.Paths.init(a, &environ),
        .stdout = &out.writer,
        .stderr = &err_out.writer,
        .self_path = "/usr/local/bin/envee",
        .trust = TrustGate.denyAll(),
    };
    const parsed = try args_mod.parse(a, &root, &.{ "eval", "bash" }, null);

    errs.reset();
    try testing.expectError(error.TrustRequired, runEvalIn(&ctx, parsed, tmp.path));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e001, d.code);
    // Код возврата 3 позволяет hook'у отличить «нужно одобрить» от поломки.
    try testing.expectEqual(@as(u8, 3), d.exitCode());
    try testing.expectEqualStrings("", out.written());
}

test "the dependency list covers configs, files and watched paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, ".env", "X=1\n");
    try tmp.write(a, "envee.toml",
        \\[env]
        \\_.file = ".env"
        \\watch = ["Cargo.toml"]
    );

    const out = try runIn(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }});
    for ([_][]const u8{ "envee.toml", ".env", "Cargo.toml" }) |name| {
        const want = try gopath.join(a, &.{ tmp.path, name });
        testing.expect(std.mem.indexOf(u8, out, want) != null) catch {
            std.debug.print("dependency list is missing {s}\n  got: {s}\n", .{ want, out });
            return error.TestExpectedEqual;
        };
    }
    // Рабочий каталог тоже в списке: без него появление нового конфига
    // рядом осталось бы незамеченным.
    try testing.expect(std.mem.indexOf(u8, out, tmp.path) != null);
}

test "unimplemented commands say so instead of pretending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try TempDir.create(a);
    defer tmp.destroy();

    try testing.expectError(error.VersionIncompatible, runIn(a, tmp, &.{"doctor"}, &.{}));
}
