//! Дерево команд envee и их выполнение.
//!
//! Порт `internal/cli/root.go`, `init.go`, `eval.go`, `deps.go`.
//!
//! Общий контекст команд и путь «найти конфиг → проверить доверие →
//! применить директивы» вынесены в context.zig: ими пользуется не только
//! eval.
//!
//! Реализованы `init`, `version`, `eval`, `resolve`, `diff` и `check`.
//! Остальные команды объявлены в дереве, чтобы справка и подсказки были
//! полными, и пока честно сообщают, что не готовы, — это лучше, чем делать
//! вид, что сработали.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const check_cmd = @import("check.zig");
const config = @import("../config.zig");
const context = @import("context.zig");
const directive = @import("../directive.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const log = @import("../log.zig");
const resolve_cmd = @import("resolve.zig");
const trust_cmd = @import("trust.zig");
const secret_cmd = @import("secret.zig");
const status_cmd = @import("status.zig");
const plugin_cmd = @import("plugin_cmd.zig");
const exec_cmd = @import("exec.zig");
const completion_cmd = @import("completion.zig");
const shell = @import("../shell/shell.zig");

pub const build_options = @import("build_options");

pub const Ctx = context.Ctx;
pub const TrustGate = context.TrustGate;

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
            .long =
            \\Run static analysis on the given file (or the discovered config in cwd)
            \\to catch common issues:
            \\  - Missing required fields
            \\  - References to non-existent files (_.file, _.script)
            \\  - Unknown secret source plugins
            \\  - Circular template dependencies
            \\  - Suspicious patterns (e.g., redact=false on a variable named *_KEY)
            ,
            .args = .any,
            .flags = &.{
                .{ .long = "strict", .help = "treat warnings as errors" },
                .{ .long = "json", .help = "JSON output" },
            },
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
            .long =
            \\The enveed daemon watches envee.toml files for changes and serves
            \\eval requests over a UNIX socket, reducing shell-hook latency to < 1ms.
            \\
            \\The daemon is optional — envee falls back to standalone mode when the
            \\daemon is not running.
            ,
            .subcommands = &.{
                .{ .name = "status", .short = "Check if the daemon is running", .flags = &.{
                    .{ .long = "json", .help = "machine-readable JSON output" },
                } },
                .{ .name = "start", .short = "Start the daemon in the background", .hidden = true },
                .{ .name = "stop", .short = "Stop the daemon", .hidden = true },
            },
        },
        .{ .name = "deny", .usage_args = "[path]", .short = "Deny envee.toml (explicit block)", .args = .any },
        .{
            .name = "diff",
            .usage_args = "<shell>",
            .short = "Show env changes since last eval",
            .long =
            \\Compute the env diff between the current shell and what `envee eval`
            \\would emit, without actually applying it. Useful for previewing changes.
            ,
            .args = .{ .exact = 1 },
            .flags = &.{
                .{ .long = "json", .help = "JSON output" },
            },
        },
        .{
            .name = "doctor",
            .short = "Run health diagnostics",
            .long =
            \\Check that envee is correctly installed and configured:
            \\  - Binary location and version
            \\  - Shell hook installed in shell config
            \\  - Trust store integrity
            \\  - Plugin discovery
            \\  - Daemon status
            ,
            .flags = &.{
                .{ .long = "fix", .help = "auto-fix safe issues (not implemented)" },
                .{ .long = "json", .help = "machine-readable JSON output" },
            },
        },
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
            .long =
            \\Inspect, install, and test secret/tool provider plugins.
            \\
            \\Plugins are external executables named envee-plugin-<name> that communicate
            \\with envee via JSON over stdin/stdout (see docs/adr/0007-plugin-protocol.md).
            ,
            .subcommands = &.{
                .{ .name = "list", .short = "List discovered plugins", .flags = &.{
                    .{ .long = "json", .help = "machine-readable JSON output" },
                } },
                .{ .name = "info", .usage_args = "<name>", .short = "Show plugin metadata", .args = .{ .exact = 1 }, .flags = &.{
                    .{ .long = "json", .help = "machine-readable JSON output" },
                } },
                .{ .name = "install", .usage_args = "<name>", .short = "Install a plugin (via brew or go install)", .args = .{ .exact = 1 }, .hidden = true },
            },
        },
        .{
            .name = "resolve",
            .short = "Compute and print the resolved environment",
            .long =
            \\Resolve all envee.toml files along the cwd hierarchy, apply directives
            \\(merge dotenv files, resolve secrets, run scripts), and print the resulting
            \\env as KEY=VALUE pairs (default) or JSON.
            \\
            \\Values marked redact are masked in both forms.
            ,
            .flags = &.{
                .{ .long = "json", .help = "JSON output" },
            },
        },
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
        .{
            .name = "status",
            .short = "Show current envee state",
            .long =
            \\Display information about the current envee configuration:
            \\  - Resolved config files (in priority order)
            \\  - Trust status of each file
            \\  - Active profile and inheritance chain
            \\  - Discovered plugins
            \\  - Daemon status
            ,
            .flags = &.{
                .{ .long = "json", .help = "machine-readable JSON output" },
                .{ .long = "show-secrets", .help = "reveal redacted values" },
                .{ .long = "trust", .help = "show trust store contents" },
                .{ .long = "plugins", .help = "show discovered plugins" },
                .{ .long = "daemon", .help = "show daemon status" },
            },
        },
        .{
            .name = "trust",
            .usage_args = "[path]",
            .short = "Trust envee.toml (review and approve its content)",
            .args = .any,
            .flags = &.{
                .{ .long = "yes", .short = 'y', .help = "auto-approve without interactive prompt" },
                .{ .long = "ttl", .kind = .{ .string = "never" }, .help = "trust TTL (e.g., 24h, 7d, never)" },
                .{ .long = "remove", .help = "remove trust entry" },
                .{ .long = "sign", .help = "sign trust entry with ed25519 key" },
                .{ .long = "key", .kind = .{ .string = "" }, .help = "path to signing key (implies --sign)" },
                .{ .long = "export", .kind = .{ .string = "" }, .help = "write the trust entry to a file so it can be shared" },
                .{ .long = "from", .kind = .{ .string = "" }, .help = "import a shared trust entry from a file (requires --public-key)" },
                .{ .long = "public-key", .kind = .{ .string = "" }, .help = "public key to verify an imported entry against" },
            },
        },
        .{ .name = "version", .short = "Show envee version" },
        // Объявлено, но не реализовано. Скрыто из справки: обещать команду,
        // которой нет, хуже, чем не показывать её.
        .{ .name = "debug", .short = "Dump internal state", .hidden = true },
        .{
            .name = "telemetry",
            .short = "Manage opt-in telemetry (not implemented)",
            .hidden = true,
            .subcommands = &.{
                .{ .name = "status", .short = "Show current telemetry setting" },
                .{ .name = "enable", .short = "Enable telemetry (opt-in)" },
                .{ .name = "disable", .short = "Disable telemetry" },
            },
        },
        .{
            .name = "upgrade",
            .usage_args = "[path]",
            .short = "Upgrade envee.toml schema to the current version",
            .hidden = true,
            .args = .any,
            .flags = &.{
                .{ .long = "from", .kind = .{ .string = "" }, .help = "explicit source version" },
                .{ .long = "to", .kind = .{ .string = "" }, .help = "explicit target version (default: current)" },
                .{ .long = "dry-run", .help = "show changes, don't apply" },
                .{ .long = "backup", .help = "create .backup file before writing" },
            },
        },
    },
};

// ---- выполнение ------------------------------------------------------------

pub const Error = context.Error || args_mod.Error || check_cmd.Error || trust_cmd.Error;

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    return runWithStopAt(ctx, parsed, "");
}

/// Как `runWithStopAt`, но с явным источником ответов для `envee trust`.
/// В проде это терминал; тесты подставляют заранее заданную
/// последовательность.
pub fn runWith(
    ctx: *Ctx,
    parsed: args_mod.Parsed,
    stop_at: []const u8,
    asker: ?trust_cmd.Asker,
) Error!void {
    const name = parsed.command.name;
    if (std.mem.eql(u8, name, "trust")) return trust_cmd.runTrust(ctx, parsed, asker);
    if (std.mem.eql(u8, name, "deny")) return trust_cmd.runDeny(ctx, parsed);
    return runWithStopAt(ctx, parsed, stop_at);
}

/// `stop_at` ограничивает подъём по дереву каталогов. В проде пусто; тесты
/// передают сюда свой временный каталог, иначе подхватились бы конфиги
/// самого репозитория.
pub fn runWithStopAt(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const name = parsed.command.name;
    if (std.mem.eql(u8, name, "version")) return runVersion(ctx);
    if (std.mem.eql(u8, name, "init")) return runInit(ctx, parsed);
    if (std.mem.eql(u8, name, "eval")) return runEval(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "resolve")) return resolve_cmd.runResolve(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "diff")) return resolve_cmd.runDiff(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "check")) return check_cmd.runWithStopAt(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "trust")) return trust_cmd.runTrust(ctx, parsed, null);
    if (std.mem.eql(u8, name, "deny")) return trust_cmd.runDeny(ctx, parsed);
    if (std.mem.eql(u8, name, "status") and parsed.path.len == 2) return status_cmd.runStatus(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "doctor")) {
        if (parsed.boolean("fix")) return notImplemented(ctx, "envee doctor --fix", "Run `envee doctor` and apply the hints it prints.");
        return status_cmd.runDoctor(ctx, parsed, stop_at);
    }
    if (std.mem.eql(u8, name, "exec")) return exec_cmd.run(ctx, parsed, stop_at);
    if (std.mem.eql(u8, name, "completion")) return completion_cmd.run(ctx, parsed);
    if (parsed.path.len >= 2 and std.mem.eql(u8, parsed.path[1].name, "secret")) return secret_cmd.run(ctx, parsed);
    if (parsed.path.len >= 2 and std.mem.eql(u8, parsed.path[1].name, "plugin")) {
        if (std.mem.eql(u8, name, "list")) return plugin_cmd.runList(ctx, parsed);
        if (std.mem.eql(u8, name, "info")) return plugin_cmd.runInfo(ctx, parsed);
        return notImplemented(ctx, "envee plugin install", "Install plugins with your package manager; envee-plugin-env ships in the same archive as envee.");
    }
    if (parsed.path.len >= 2 and std.mem.eql(u8, parsed.path[1].name, "daemon")) {
        if (std.mem.eql(u8, name, "status")) return status_cmd.runDaemonStatus(ctx, parsed);
        if (std.mem.eql(u8, name, "start")) return notImplemented(ctx, "envee daemon start", "Run the daemon directly for now: `enveed &`.");
        return notImplemented(ctx, "envee daemon stop", "Stop it with your process manager, or `pkill enveed`.");
    }
    if (parsed.path.len >= 2 and std.mem.eql(u8, parsed.path[1].name, "telemetry")) {
        if (std.mem.eql(u8, name, "status")) return ctx.stdout.writeAll("telemetry: off (envee collects no telemetry)\n");
        if (std.mem.eql(u8, name, "telemetry")) return; // родительская команда без подкоманды — как в cobra, показывается справка выше
        const what = try std.fmt.allocPrint(ctx.arena, "envee telemetry {s}", .{name});
        return notImplemented(ctx, what, "envee collects no telemetry; there is nothing to configure.");
    }
    if (std.mem.eql(u8, name, "upgrade")) return notImplemented(ctx, "envee upgrade", "Only schema " ++ config.schema_version ++ " exists, so no migration is possible yet.");
    if (std.mem.eql(u8, name, "debug")) return notImplemented(ctx, "envee debug", "Use `envee status`, `envee resolve` and `envee doctor`, or --log-level=debug.");
    return notImplemented(ctx, try parsed.commandPath(ctx.arena), "");
}

/// Команда есть в дереве, но не делает того, о чём просят. Раньше такие
/// печатали сообщение и выходили с нулём, и скрипты проходили впустую;
/// команда, не сделавшая работу, обязана упасть — E014, как в Go.
fn notImplemented(ctx: *Ctx, what: []const u8, hint: []const u8) Error!void {
    const S = struct {
        var kv: [1]errs.KV = .{.{ .key = "status", .value = "planned" }};
    };
    return errs.fail(.{
        .code = .e014,
        .summary = try std.fmt.allocPrint(ctx.arena, "{s} is not implemented yet", .{what}),
        .context = &S.kv,
        .hint = hint,
    }, error.VersionIncompatible);
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
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse return context.unsupportedShell(parsed.args[0]);
    try adapter.writeInit(ctx.stdout, ctx.self_path);
}

/// `envee eval <shell>` — то, что вызывает hook на каждом приглашении.
fn runEval(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse
        return context.unsupportedShell(parsed.args[0]);

    const r = try context.resolveEnv(ctx, parsed.str("profile"), stop_at);
    try context.writeShellDiff(ctx, ctx.stdout, adapter, r.result);

    // Список зависимостей позволяет hook'у на следующем приглашении вообще
    // не запускать envee.
    if (adapter.supportsFastPath()) {
        const deps = try evalDeps(ctx.arena, r.loaded.cfg, ctx.cwd, r.loaded.config_root);
        try adapter.writeFastPath(ctx.stdout, deps);
    }
}

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
const harness = @import("test_harness.zig");

test "version prints the build metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const out = try harness.run(a, tmp, &.{"version"}, &.{});
    try testing.expect(std.mem.startsWith(u8, out, "envee version "));
    try testing.expect(std.mem.indexOf(u8, out, "commit ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig ") != null);
}

test "init emits the hook for each shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    for ([_][]const u8{ "bash", "zsh", "fish", "nu", "pwsh" }) |sh| {
        const out = try harness.run(a, tmp, &.{ "init", sh }, &.{});
        try testing.expect(out.len > 100);
        try testing.expect(std.mem.indexOf(u8, out, "/usr/local/bin/envee") != null);
        try testing.expect(std.mem.indexOf(u8, out, "{{.SelfPath}}") == null);
    }
}

test "init refuses an unsupported shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{ "init", "tcsh" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e003, d.code);
    try testing.expectEqualStrings("tcsh", d.context[0].value);
}

test "eval exports variables for bash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\PORT = 5432
        \\SPACED = "a b"
    );

    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin:/bin" }});
    try testing.expect(std.mem.indexOf(u8, out, "export PORT=5432;\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "export SERVICE_NAME=myapp;\n") != null);
    // Значение с пробелом обязано приехать в кавычках.
    try testing.expect(std.mem.indexOf(u8, out, "export SPACED='a b';\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "__envee_deps=(") != null);
}

// Go передавал в setPath ПОЛНЫЙ новый PATH, а адаптер дописывал к нему ещё
// и текущий: из двух записей получалось семь вместо пяти, с дублями.
test "eval does not duplicate the existing PATH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\n_.path = [\"./bin\", \"./tools\"]\n");

    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin:/bin" }});

    const line_end = std.mem.indexOfScalar(u8, out, '\n').?;
    const path_line = out[0..line_end];
    try testing.expect(std.mem.startsWith(u8, path_line, "export PATH="));
    try testing.expect(std.mem.indexOf(u8, path_line, "/usr/bin") == null);
    try testing.expect(std.mem.endsWith(u8, path_line, ":\"$PATH\";"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, path_line, tmp.path));
}

test "eval skips a path entry already present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\n_.path = [\"./bin\"]\n");

    const bin = try gopath.join(a, &.{ tmp.path, "bin" });
    const already = try std.fmt.allocPrint(a, "{s}:/usr/bin", .{bin});
    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", already }});
    try testing.expect(std.mem.indexOf(u8, out, "export PATH=") == null);
}

test "eval skips variables that already hold the same value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nSAME = \"v\"\nCHANGED = \"new\"\n");

    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{
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
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\[profiles.dev.env]
        \\WHICH = "dev"
        \\[profiles.prod.env]
        \\WHICH = "prod"
    );

    const by_flag = try harness.run(a, tmp, &.{ "--profile", "prod", "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }});
    try testing.expect(std.mem.indexOf(u8, by_flag, "export WHICH=prod;") != null);

    const by_env = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{
        .{ "PATH", "/usr/bin" },
        .{ "ENVEE_PROFILE", "dev" },
    });
    try testing.expect(std.mem.indexOf(u8, by_env, "export WHICH=dev;") != null);
}

test "eval renders JSON for nushell and shell code for the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n");

    const nu = try harness.run(a, tmp, &.{ "eval", "nu" }, &.{.{ "PATH", "/usr/bin" }});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, nu, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("1", parsed.value.object.get("set").?.object.get("A").?.string);
    try testing.expect(std.mem.indexOf(u8, nu, "__envee_deps") == null);

    const fish = try harness.run(a, tmp, &.{ "eval", "fish" }, &.{.{ "PATH", "/usr/bin" }});
    try testing.expect(std.mem.indexOf(u8, fish, "set -gx A '1'\n") != null);
    try testing.expect(std.mem.indexOf(u8, fish, "set -g __envee_deps") != null);
}

test "eval without a config reports where it looked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.FileNotFound, harness.run(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e012, d.code);
    try testing.expectEqual(@as(u8, 4), d.exitCode());
}

test "a broken config reports the file and the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\nbroken = = =\n");

    errs.reset();
    try testing.expectError(error.ConfigParse, harness.run(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e002, d.code);
    try testing.expectEqualStrings("2", d.context[1].value);
}

// Гейт доверия — единственная дверь, через которую конфиг попадает в
// оболочку. По умолчанию она закрыта.
test "eval refuses an untrusted config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n");

    errs.reset();
    try testing.expectError(error.TrustRequired, harness.runUntrusted(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e001, d.code);
    // Код возврата 3 позволяет hook'у отличить «нужно одобрить» от поломки.
    try testing.expectEqual(@as(u8, 3), d.exitCode());
}

test "the dependency list covers configs, files and watched paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.writeFile(a, ".env", "X=1\n");
    try tmp.write(a,
        \\[env]
        \\_.file = ".env"
        \\watch = ["Cargo.toml"]
    );

    const out = try harness.run(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }});
    for ([_][]const u8{ "envee.toml", ".env", "Cargo.toml" }) |name| {
        const want = try gopath.join(a, &.{ tmp.path, name });
        testing.expect(std.mem.indexOf(u8, out, want) != null) catch {
            std.debug.print("dependency list is missing {s}\n  got: {s}\n", .{ want, out });
            return error.TestExpectedEqual;
        };
    }
    try testing.expect(std.mem.indexOf(u8, out, tmp.path) != null);
}

// Ошибка применения директив обязана дойти до пользователя с кодом,
// объяснением и подсказкой, а не голым именем ошибки.
test "a directive error carries a full diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\[profiles.prod]
        \\required = ["NOWHERE"]
        \\[profiles.prod.env]
        \\OTHER = "1"
    );

    errs.reset();
    try testing.expectError(
        error.RequiredVarMissing,
        harness.run(a, tmp, &.{ "--profile", "prod", "eval", "bash" }, &.{}),
    );
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e008, d.code);
    try testing.expectEqual(@as(u8, 4), d.exitCode());
    try testing.expectEqualStrings("NOWHERE", d.context[0].value);
    // Имя профиля настоящее, а не литерал "?", как в Go.
    try testing.expectEqualStrings("prod", d.context[1].value);
    try testing.expect(d.hint.len > 0);
}

test "a template cycle carries the chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"{{env.B}}\"\nB = \"{{env.A}}\"\n");

    errs.reset();
    try testing.expectError(error.CycleDetected, harness.run(a, tmp, &.{ "eval", "bash" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e007, d.code);
    try testing.expect(std.mem.indexOf(u8, d.context[0].value, "->") != null);
}

test "unimplemented commands say so instead of pretending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    try testing.expectError(error.VersionIncompatible, harness.run(a, tmp, &.{"debug"}, &.{}));
}
