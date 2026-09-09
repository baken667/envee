//! `envee status`, `envee doctor`, `envee daemon status`.
//!
//! Порт `internal/cli/status.go` и `diag.go`. Это команды осмотра: они не
//! падают на отсутствующем или неодобренном конфиге, а рассказывают о нём.
//! Окружение вычисляется только когда все файлы одобрены — директивы умеют
//! запускать плагины, и неодобренному конфигу это нельзя.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const config = @import("../config.zig");
const directive = @import("../directive.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const plugin = @import("../plugin.zig");
const plugin_cmd = @import("plugin_cmd.zig");
const resolver_mod = @import("../resolver.zig");
const store_mod = @import("../trust/store.zig");
const Ctx = context.Ctx;

pub const Error = context.Error;

const build_options = @import("build_options");
const redacted_placeholder = "***REDACTED***";
const pad = "                                        ";

// ---- daemon ------------------------------------------------------------------

pub const DaemonState = struct {
    running: bool = false,
    socket: []const u8,
    lock: []const u8,
    detail: []const u8 = "",
};

/// Жив ли демон. Наличия файла сокета мало: упавший демон оставляет его
/// за собой. Единственный надёжный признак — удачное подключение.
pub fn probeDaemon(ctx: *Ctx) Allocator.Error!DaemonState {
    var st: DaemonState = .{ .socket = ctx.paths.socket, .lock = ctx.paths.lock_file };
    _ = Io.Dir.cwd().statFile(ctx.io, st.socket, .{}) catch {
        st.detail = try std.fmt.allocPrint(ctx.arena, "no socket at {s}", .{st.socket});
        return st;
    };
    const addr = Io.net.UnixAddress.init(st.socket) catch {
        st.detail = "socket path is too long";
        return st;
    };
    const stream = addr.connect(ctx.io) catch |err| {
        st.detail = try std.fmt.allocPrint(ctx.arena, "socket exists but is not accepting connections (stale): {s}", .{@errorName(err)});
        return st;
    };
    stream.close(ctx.io);
    st.running = true;
    return st;
}

fn writeDaemonJson(w: *Writer, st: DaemonState, indent: usize) Writer.Error!void {
    const in1 = pad[0 .. indent + 2];
    try w.print("{{\n{s}\"running\": {},\n{s}\"socket\": ", .{ in1, st.running, in1 });
    try std.json.Stringify.value(st.socket, .{}, w);
    try w.print(",\n{s}\"lock\": ", .{in1});
    try std.json.Stringify.value(st.lock, .{}, w);
    if (st.detail.len > 0) {
        try w.print(",\n{s}\"detail\": ", .{in1});
        try std.json.Stringify.value(st.detail, .{}, w);
    }
    try w.print("\n{s}}}", .{pad[0..indent]});
}

pub fn runDaemonStatus(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const st = try probeDaemon(ctx);
    const w = ctx.stdout;
    if (parsed.boolean("json")) {
        try writeDaemonJson(w, st, 0);
        try w.writeAll("\n");
        return;
    }
    if (st.running) {
        try w.print("enveed is running (socket {s})\n", .{st.socket});
        return;
    }
    try w.writeAll("enveed is not running\n");
    if (st.detail.len > 0) try w.print("  {s}\n", .{st.detail});
    try w.writeAll("  envee works without it; the daemon only reduces hook latency.\n");
    try w.writeAll("  Start it with: enveed &\n");
}

// ---- status ------------------------------------------------------------------

const ProfileSource = enum {
    flag,
    env,
    config,

    fn name(s: ProfileSource) []const u8 {
        return switch (s) {
            .flag => "--profile flag",
            .env => "$ENVEE_PROFILE",
            .config => "config default",
        };
    }
};

pub fn runStatus(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const arena = ctx.arena;
    const show_secrets = parsed.boolean("show-secrets");

    var profile = parsed.str("profile");
    var source: ProfileSource = .flag;
    if (profile.len == 0) {
        profile = ctx.environ.get("ENVEE_PROFILE") orelse "";
        source = .env;
    }
    if (profile.len == 0) source = .config;

    var r = resolver_mod.Resolver.init(ctx.cwd, ctx.paths);
    r.profile = profile;
    r.stop_at_root = stop_at;
    const files = r.discover(arena, ctx.io) catch &.{};
    const cfg: ?config.Config = r.loadAll(arena, ctx.io, null) catch null;

    // Профиль по умолчанию из конфига — тот же приоритет, что у eval.
    // Без этого status рисовал бы `{{profile}}` пустым и расходился с eval.
    if (profile.len == 0) if (cfg) |c| {
        profile = c.profile;
    };

    var config_root: []const u8 = "";
    var untrusted: []const config.SourceFile = &.{};
    if (cfg) |c| {
        config_root = gopath.dirname(arena, c.path) catch c.path;
        untrusted = try ctx.trust.untrusted(arena, c.sources);
    }

    var result: ?directive.Result = null;
    if (cfg) |c| if (untrusted.len == 0) {
        var dispatcher = try plugin.dispatcherFor(arena, ctx.io, ctx.environ, c);
        const resolver: ?directive.PluginResolver = if (dispatcher) |*d| d.resolver() else null;
        result = directive.apply(arena, ctx.io, c, .{
            .config_root = config_root,
            .profile = profile,
            .cwd = ctx.cwd,
            .os_env = &ctx.os_env,
        }, resolver, null) catch null;
    };

    var redacted: std.ArrayList([]const u8) = .empty;
    if (result) |res| for (res.env.entries.items) |e| {
        if (e.redacted) try redacted.append(arena, e.key);
    };

    var trust_entries: ?[]const store_mod.Entry = null;
    if (parsed.boolean("trust")) {
        const store: store_mod.Store = .{
            .root = ctx.paths.trust_store,
            .io = ctx.io,
            .now_ns = Io.Timestamp.now(ctx.io, .real).nanoseconds,
            .user = "",
            .tool_version = ctx.tool_version,
        };
        trust_entries = store.list(arena) catch |err| return liftStoreError(err, ctx.paths.trust_store);
    }
    const plugins: ?[]const plugin_cmd.Discovered = if (parsed.boolean("plugins")) try plugin_cmd.discover(ctx) else null;
    const daemon: ?DaemonState = if (parsed.boolean("daemon")) try probeDaemon(ctx) else null;

    const w = ctx.stdout;
    if (parsed.boolean("json")) {
        try w.writeAll("{\n  \"cwd\": ");
        try std.json.Stringify.value(ctx.cwd, .{}, w);
        if (profile.len > 0) {
            try w.writeAll(",\n  \"profile\": ");
            try std.json.Stringify.value(profile, .{}, w);
        }
        if (config_root.len > 0) {
            try w.writeAll(",\n  \"config_root\": ");
            try std.json.Stringify.value(config_root, .{}, w);
        }
        // Go: `files` — срез из Discover, у пустого результата nil → null.
        try w.writeAll(",\n  \"files\": ");
        if (files.len == 0) try w.writeAll("null") else try writeStringArray(w, files, 2);
        try w.writeAll(",\n  \"untrusted\": ");
        var untrusted_paths: std.ArrayList([]const u8) = .empty;
        for (untrusted) |src| try untrusted_paths.append(arena, src.path);
        try writeStringArray(w, untrusted_paths.items, 2);
        if (result) |res| {
            try w.writeAll(",\n  \"env\": ");
            if (res.env.entries.items.len == 0) {
                try w.writeAll("{}");
            } else {
                try w.writeAll("{");
                for (res.env.entries.items, 0..) |e, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("\n    ");
                    try std.json.Stringify.value(e.key, .{}, w);
                    try w.writeAll(": ");
                    try std.json.Stringify.value(if (e.redacted and !show_secrets) redacted_placeholder else e.value, .{}, w);
                }
                try w.writeAll("\n  }");
            }
            if (redacted.items.len > 0) {
                try w.writeAll(",\n  \"redacted\": ");
                try writeStringArray(w, redacted.items, 2);
            }
        }
        if (trust_entries) |entries| if (entries.len > 0) {
            try w.writeAll(",\n  \"trust_store\": [");
            for (entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("\n    ");
                try writeEntryJsonIndented(w, e, 4);
            }
            try w.writeAll("\n  ]");
        };
        if (plugins) |found| if (found.len > 0) {
            try w.writeAll(",\n  \"plugins\": ");
            try plugin_cmd.writeListJson(w, found, 2);
        };
        if (daemon) |st| {
            try w.writeAll(",\n  \"daemon\": ");
            try writeDaemonJson(w, st, 2);
        }
        try w.writeAll("\n}\n");
        return;
    }

    try w.writeAll("envee status\n============\n\n");
    try w.print("Working dir: {s}\n", .{ctx.cwd});
    if (cfg) |c| {
        try w.print("Active profile: {s} (from {s})\n", .{ profile, source.name() });
        try w.print("Config root:   {s}\n", .{config_root});
        try w.print("Config hash:   {s}\n", .{c.file_hash});
    }

    try w.writeAll("\nResolved config files (priority high → low):\n");
    for (files, 1..) |f, i| try w.print("  {d}. {s}\n", .{ i, f });
    if (files.len == 0) try w.writeAll("  (none found)\n");

    if (cfg) |c| {
        try w.writeAll("\nDirectives:\n");
        try w.print("  _.file:     {d} entries\n", .{c.directives.file.len});
        try w.print("  _.path:     {d} entries\n", .{c.directives.path.len});
        try w.print("  _.script:   {d} entries\n", .{c.directives.script.len});
        try w.print("  _.secret:   {d} entries\n", .{(try c.secretRefs(arena)).len});
    }

    if (untrusted.len > 0) {
        try w.writeAll("\nNot trusted (env not resolved — run `envee trust`):\n");
        for (untrusted) |src| try w.print("  {s}\n", .{src.path});
    } else if (result) |res| {
        try w.print("\nResolved env: {d} variables\n", .{res.env.entries.items.len});
        for (res.env.entries.items) |e| {
            const value = if (e.redacted and !show_secrets) redacted_placeholder else e.value;
            try w.print("  {s} = {s} (source: {s})\n", .{ e.key, value, e.source });
        }
        if (redacted.items.len > 0 and !show_secrets) {
            try w.print("\n  {d} value(s) hidden; pass --show-secrets to reveal them.\n", .{redacted.items.len});
        }
    }

    if (trust_entries) |entries| {
        try w.print("\nTrust store ({s}): {d} entry/entries\n", .{ ctx.paths.trust_store, entries.len });
        for (entries) |e| {
            try w.print("  {s}\n", .{e.file_path});
            try w.print("    hash:    {s}\n", .{e.file_hash});
            try w.print("    trusted: {s} by {s} (envee {s})\n", .{ e.trusted_at, e.trusted_by, e.tool_version });
            try w.print("    expires: {s}\n", .{if (store_mod.hasExpiry(e)) e.expires_at else "never"});
            if (e.signature) |sig| {
                try w.print("    signed:  {s} by {s} (key {s})\n", .{ sig.algorithm, e.trusted_by, sig.key_id });
            }
        }
    }

    if (plugins) |found| {
        try w.print("\nPlugins: {d} discovered\n", .{found.len});
        for (found) |d| {
            if (d.metadata) |md| {
                try w.print("  {s:<12} {s} (v{s}, api {d})\n", .{ d.name, d.path, md.version, md.api_version });
            } else {
                try w.print("  {s:<12} {s} (handshake failed: {s})\n", .{ d.name, d.path, d.err });
            }
        }
    }

    if (daemon) |st| {
        try w.writeAll("\n");
        if (st.running) {
            try w.print("Daemon: running at {s}\n", .{st.socket});
        } else {
            try w.writeAll("Daemon: not running (optional)\n");
            if (st.detail.len > 0) try w.print("  {s}\n", .{st.detail});
        }
    }
}

fn writeStringArray(w: *Writer, items: []const []const u8, indent: usize) Writer.Error!void {
    if (items.len == 0) return w.writeAll("[]");
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\n{s}", .{pad[0 .. indent + 2]});
        try std.json.Stringify.value(item, .{}, w);
    }
    try w.print("\n{s}]", .{pad[0..indent]});
}

/// Запись хранилища как в файле (`writeEntryJson`), но с отступом внутри
/// массива: encoding/json в Go отступает вложенное на уровень контейнера.
fn writeEntryJsonIndented(w: *Writer, e: store_mod.Entry, indent: usize) Writer.Error!void {
    var buf: [4096]u8 = undefined;
    var fixed: Writer = .fixed(&buf);
    store_mod.writeEntryJson(&fixed, e) catch return error.WriteFailed;
    const body = std.mem.trimEnd(u8, fixed.buffered(), "\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try w.print("\n{s}", .{pad[0..indent]});
        first = false;
        try w.writeAll(line);
    }
}

fn liftStoreError(err: anyerror, root: []const u8) Error {
    const S = struct {
        var kv: [2]errs.KV = undefined;
    };
    S.kv = .{
        .{ .key = "path", .value = root },
        .{ .key = "detail", .value = @errorName(err) },
    };
    return errs.fail(.{
        .code = .e013,
        .summary = "cannot read trust store",
        .context = &S.kv,
    }, error.PermissionDenied);
}

// ---- doctor ------------------------------------------------------------------

const DiagStatus = enum {
    ok,
    warn,
    fail,

    fn name(s: DiagStatus) []const u8 {
        return @tagName(s);
    }

    fn mark(s: DiagStatus) []const u8 {
        return switch (s) {
            .ok => "ok  ",
            .warn => "warn",
            .fail => "FAIL",
        };
    }
};

const Diagnostic = struct {
    name: []const u8,
    status: DiagStatus,
    detail: []const u8,
    hint: []const u8 = "",
};

/// Имена ОС и архитектуры как у Go (`runtime.GOOS/GOARCH`): вывод doctor
/// должен читаться одинаково у обеих реализаций.
fn goos() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        else => @tagName(builtin.os.tag),
    };
}

fn goarch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        .x86 => "386",
        else => @tagName(builtin.cpu.arch),
    };
}

/// Есть ли строка `envee init` в rc-файле оболочки. Лучшее из возможного:
/// нечитаемый или необычный rc просто считается «не найдено».
fn hookInstalled(ctx: *Ctx, shell_path: []const u8) Allocator.Error!?[]const u8 {
    const home = ctx.environ.get("HOME") orelse return null;
    const base = std.fs.path.basename(shell_path);
    const candidates: []const []const u8 = if (std.mem.eql(u8, base, "bash"))
        &.{ ".bashrc", ".bash_profile", ".profile" }
    else if (std.mem.eql(u8, base, "zsh"))
        &.{ ".zshrc", ".zprofile" }
    else if (std.mem.eql(u8, base, "fish"))
        &.{".config/fish/config.fish"}
    else
        &.{".profile"};
    for (candidates) |c| {
        const file = try std.fs.path.join(ctx.arena, &.{ home, c });
        const data = Io.Dir.cwd().readFileAlloc(ctx.io, file, ctx.arena, .unlimited) catch continue;
        if (std.mem.indexOf(u8, data, "envee init") != null) return file;
    }
    return null;
}

pub fn runDoctor(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const arena = ctx.arena;
    var d: std.ArrayList(Diagnostic) = .empty;

    try d.append(arena, .{ .name = "binary", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} ({s}/{s})", .{ ctx.self_path, goos(), goarch() }) });
    if (std.mem.eql(u8, build_options.version, "0.0.0-dev")) {
        try d.append(arena, .{
            .name = "version",
            .status = .warn,
            .detail = "0.0.0-dev — built without release ldflags",
            .hint = "Release builds report a real version. `make build` sets them.",
        });
    } else {
        try d.append(arena, .{ .name = "version", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} (commit {s}, built {s})", .{ build_options.version, build_options.commit, build_options.date }) });
    }

    // envee должен быть в PATH, иначе интерактивно им не воспользоваться.
    if (try plugin.lookPath(arena, ctx.io, ctx.environ.get("PATH") orelse "", "envee")) |p| {
        try d.append(arena, .{ .name = "PATH", .status = .ok, .detail = p });
    } else {
        try d.append(arena, .{
            .name = "PATH",
            .status = .warn,
            .detail = "envee is not on $PATH",
            .hint = "The shell hook calls envee by absolute path, so this is not fatal, but `envee` will not work interactively.",
        });
    }

    const shell_name = ctx.environ.get("SHELL") orelse "";
    if (shell_name.len == 0) {
        try d.append(arena, .{ .name = "shell", .status = .warn, .detail = "$SHELL is not set" });
    } else {
        try d.append(arena, .{ .name = "shell", .status = .ok, .detail = shell_name });
        if (try hookInstalled(ctx, shell_name)) |file| {
            try d.append(arena, .{ .name = "shell hook", .status = .ok, .detail = try std.fmt.allocPrint(arena, "installed in {s}", .{file}) });
        } else {
            try d.append(arena, .{
                .name = "shell hook",
                .status = .warn,
                .detail = "no `envee init` line found in your shell rc",
                .hint = try std.fmt.allocPrint(arena, "Add: eval \"$(envee init {s})\"", .{std.fs.path.basename(shell_name)}),
            });
        }
    }

    for ([_][2][]const u8{
        .{ "config dir", ctx.paths.config },
        .{ "data dir", ctx.paths.data },
        .{ "trust store", ctx.paths.trust_store },
    }) |dir| {
        if (Io.Dir.cwd().statFile(ctx.io, dir[1], .{})) |_| {
            try d.append(arena, .{ .name = dir[0], .status = .ok, .detail = dir[1] });
        } else |err| switch (err) {
            error.FileNotFound => try d.append(arena, .{ .name = dir[0], .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s} (not created yet)", .{dir[1]}) }),
            else => try d.append(arena, .{ .name = dir[0], .status = .fail, .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ dir[1], @errorName(err) }), .hint = "Check filesystem permissions." }),
        }
    }

    const store: store_mod.Store = .{
        .root = ctx.paths.trust_store,
        .io = ctx.io,
        .now_ns = Io.Timestamp.now(ctx.io, .real).nanoseconds,
        .user = "",
        .tool_version = ctx.tool_version,
    };
    if (store.list(arena)) |entries| {
        try d.append(arena, .{ .name = "trust entries", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{d}", .{entries.len}) });
    } else |err| {
        try d.append(arena, .{ .name = "trust entries", .status = .fail, .detail = @errorName(err), .hint = try std.fmt.allocPrint(arena, "The trust store may be corrupt; inspect {s}", .{ctx.paths.trust_store}) });
    }

    const found = try plugin_cmd.discover(ctx);
    if (found.len == 0) {
        try d.append(arena, .{ .name = "plugins", .status = .ok, .detail = "none discovered" });
    } else {
        var broken: std.ArrayList([]const u8) = .empty;
        for (found) |p| if (p.metadata == null) try broken.append(arena, p.name);
        const detail = try std.fmt.allocPrint(arena, "{d} discovered", .{found.len});
        if (broken.items.len > 0) {
            try d.append(arena, .{
                .name = "plugins",
                .status = .warn,
                .detail = try std.fmt.allocPrint(arena, "{s}, metadata handshake failed for: {s}", .{ detail, try joinComma(arena, broken.items) }),
                .hint = "Run `envee plugin info <name>` for the error.",
            });
        } else {
            try d.append(arena, .{ .name = "plugins", .status = .ok, .detail = detail });
        }
    }

    const daemon = try probeDaemon(ctx);
    if (daemon.running) {
        try d.append(arena, .{ .name = "daemon", .status = .ok, .detail = try std.fmt.allocPrint(arena, "running at {s}", .{daemon.socket}) });
    } else {
        try d.append(arena, .{ .name = "daemon", .status = .ok, .detail = "not running (optional)" });
    }

    var r = resolver_mod.Resolver.init(ctx.cwd, ctx.paths);
    r.stop_at_root = stop_at;
    const files = r.discover(arena, ctx.io) catch &.{};
    if (files.len == 0) {
        try d.append(arena, .{ .name = "config", .status = .ok, .detail = try std.fmt.allocPrint(arena, "no envee.toml found from {s}", .{ctx.cwd}) });
    } else {
        var untrusted: std.ArrayList([]const u8) = .empty;
        if (r.loadAll(arena, ctx.io, null)) |cfg| {
            for (try ctx.trust.untrusted(arena, cfg.sources)) |src| try untrusted.append(arena, src.path);
        } else |_| {}
        const detail = try std.fmt.allocPrint(arena, "{d} file(s) would be loaded here", .{files.len});
        if (untrusted.items.len > 0) {
            try d.append(arena, .{
                .name = "config",
                .status = .warn,
                .detail = try std.fmt.allocPrint(arena, "{s}; not trusted: {s}", .{ detail, try joinComma(arena, untrusted.items) }),
                .hint = "Run `envee trust` to review and approve them.",
            });
        } else {
            try d.append(arena, .{ .name = "config", .status = .ok, .detail = try std.fmt.allocPrint(arena, "{s}, all trusted", .{detail}) });
        }
    }

    var failures: usize = 0;
    var warnings: usize = 0;
    for (d.items) |x| switch (x.status) {
        .fail => failures += 1,
        .warn => warnings += 1,
        .ok => {},
    };

    const w = ctx.stdout;
    if (parsed.boolean("json")) {
        try w.writeAll("{\n  \"diagnostics\": [");
        for (d.items, 0..) |x, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("\n    {\n      \"name\": ");
            try std.json.Stringify.value(x.name, .{}, w);
            try w.writeAll(",\n      \"status\": ");
            try std.json.Stringify.value(x.status.name(), .{}, w);
            try w.writeAll(",\n      \"detail\": ");
            try std.json.Stringify.value(x.detail, .{}, w);
            if (x.hint.len > 0) {
                try w.writeAll(",\n      \"hint\": ");
                try std.json.Stringify.value(x.hint, .{}, w);
            }
            try w.writeAll("\n    }");
        }
        try w.print("\n  ],\n  \"failures\": {d},\n  \"warnings\": {d},\n  \"ok\": {}\n}}\n", .{ failures, warnings, failures == 0 });
    } else {
        try w.writeAll("envee doctor\n============\n");
        for (d.items) |x| {
            try w.print("  [{s}] {s:<14} {s}\n", .{ x.status.mark(), x.name, x.detail });
            if (x.hint.len > 0) try w.print("         {s:<14} {s}\n", .{ "", x.hint });
        }
        try w.writeAll("\n");
        if (failures == 0 and warnings == 0) {
            try w.writeAll("Everything looks fine.\n");
        } else {
            try w.print("{d} failure(s), {d} warning(s)\n", .{ failures, warnings });
        }
    }

    if (failures > 0) {
        const S = struct {
            var kv: [1]errs.KV = undefined;
        };
        S.kv[0] = .{ .key = "failures", .value = try std.fmt.allocPrint(arena, "{d}", .{failures}) };
        return errs.fail(.{
            .code = .e013,
            .summary = "doctor found problems",
            .context = &S.kv,
        }, error.PermissionDenied);
    }
}

fn joinComma(arena: Allocator, items: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, ", ", items);
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

test "status without a config says so and still lists nothing as untrusted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const out = try harness.run(a, tmp, &.{"status"}, &.{});
    try testing.expect(std.mem.startsWith(u8, out, "envee status\n============\n\nWorking dir: "));
    try testing.expect(std.mem.indexOf(u8, out, "Resolved config files (priority high → low):\n  (none found)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Active profile") == null);

    const json = try harness.run(a, tmp, &.{ "status", "--json" }, &.{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try testing.expect(v.object.get("files").? == .null);
    try testing.expectEqual(@as(usize, 0), v.object.get("untrusted").?.array.items.len);
    try testing.expect(v.object.get("env") == null);
}

test "status shows the untrusted file and, once trusted, the resolved env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\schema = "envee/v1"
        \\profile = "dev"
        \\[env]
        \\A = "1"
        \\KEY = { value = "s3cret", redact = true }
        \\
    );

    const before = try harness.runReal(a, tmp, &.{"status"}, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, before, "Active profile: dev (from config default)\n") != null);
    try testing.expect(std.mem.indexOf(u8, before, "Directives:\n  _.file:     0 entries\n  _.path:     0 entries\n  _.script:   0 entries\n  _.secret:   0 entries\n") != null);
    try testing.expect(std.mem.indexOf(u8, before, "Not trusted (env not resolved — run `envee trust`):\n") != null);
    try testing.expect(std.mem.indexOf(u8, before, "Resolved env") == null);

    _ = try harness.runReal(a, tmp, &.{ "trust", "--yes" }, &.{}, null);
    const after = try harness.runReal(a, tmp, &.{"status"}, &.{.{ "ENVEE_PROFILE", "prod" }}, null);
    try testing.expect(std.mem.indexOf(u8, after, "Active profile: prod (from $ENVEE_PROFILE)\n") != null);
    try testing.expect(std.mem.indexOf(u8, after, "Resolved env: 2 variables\n  A = 1 (source: toml)\n  KEY = ***REDACTED*** (source: toml)\n\n  1 value(s) hidden; pass --show-secrets to reveal them.\n") != null);

    const shown = try harness.runReal(a, tmp, &.{ "status", "--show-secrets", "--profile", "qa" }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, shown, "Active profile: qa (from --profile flag)\n") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "KEY = s3cret (source: toml)") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "hidden;") == null);

    // --trust перечисляет запись; --json отдаёт то же структурой.
    const with_trust = try harness.runReal(a, tmp, &.{ "status", "--trust" }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, with_trust, "): 1 entry/entries\n") != null);
    try testing.expect(std.mem.indexOf(u8, with_trust, "    expires: never\n") != null);
    try testing.expect(std.mem.indexOf(u8, with_trust, "by tester (envee 0.4.0-test)") != null);

    const json = try harness.runReal(a, tmp, &.{ "status", "--json", "--trust", "--daemon" }, &.{}, null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try testing.expectEqualStrings("dev", v.object.get("profile").?.string);
    try testing.expectEqual(@as(usize, 1), v.object.get("files").?.array.items.len);
    try testing.expectEqualStrings("***REDACTED***", v.object.get("env").?.object.get("KEY").?.string);
    try testing.expectEqualStrings("KEY", v.object.get("redacted").?.array.items[0].string);
    try testing.expectEqual(@as(i64, 2), v.object.get("trust_store").?.array.items[0].object.get("version").?.integer);
    try testing.expect(!v.object.get("daemon").?.object.get("running").?.bool);
}

test "daemon status reports a missing socket without failing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const out = try harness.run(a, tmp, &.{ "daemon", "status" }, &.{.{ "XDG_RUNTIME_DIR", try tmp.join(a, "run") }});
    try testing.expect(std.mem.startsWith(u8, out, "enveed is not running\n  no socket at "));
    try testing.expect(std.mem.indexOf(u8, out, "Start it with: enveed &\n") != null);

    const json = try harness.run(a, tmp, &.{ "daemon", "status", "--json" }, &.{});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try testing.expect(!v.object.get("running").?.bool);
    try testing.expect(v.object.get("detail").?.string.len > 0);
}

test "doctor reports every check and fails only on failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.writeFile(a, ".zshrc", "eval \"$(envee init zsh)\"\n");
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const env = [_][2][]const u8{ .{ "SHELL", "/bin/zsh" }, .{ "PATH", "/usr/bin:/bin" } };
    const out = try harness.runRealFull(a, tmp, &.{"doctor"}, &env, null);
    try testing.expect(std.mem.startsWith(u8, out.stdout, "envee doctor\n============\n  [ok  ] binary         "));
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [warn] PATH           envee is not on $PATH\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [ok  ] shell          /bin/zsh\n  [ok  ] shell hook     installed in ") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [ok  ] trust entries  0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [ok  ] plugins        none discovered\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [ok  ] daemon         not running (optional)\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "  [warn] config         1 file(s) would be loaded here; not trusted: ") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "Run `envee trust` to review and approve them.\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.stdout, " warning(s)\n") != null);

    _ = try harness.runReal(a, tmp, &.{ "trust", "--yes" }, &.{}, null);
    const json = try harness.runReal(a, tmp, &.{ "doctor", "--json" }, &env, null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try testing.expect(v.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 0), v.object.get("failures").?.integer);
    var config_ok = false;
    for (v.object.get("diagnostics").?.array.items) |item| {
        const name = item.object.get("name").?.string;
        if (std.mem.eql(u8, name, "config")) {
            try testing.expectEqualStrings("1 file(s) would be loaded here, all trusted", item.object.get("detail").?.string);
            config_ok = true;
        }
        if (std.mem.eql(u8, name, "trust entries")) try testing.expectEqualStrings("1", item.object.get("detail").?.string);
    }
    try testing.expect(config_ok);

    // --fix — честно не реализовано: E014.
    errs.reset();
    try testing.expectError(error.VersionIncompatible, harness.run(a, tmp, &.{ "doctor", "--fix" }, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e014, d.code);
    try testing.expectEqualStrings("envee doctor --fix is not implemented yet", d.summary);
}

test "hidden commands fail with E014 instead of pretending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const cases = [_]struct { argv: []const []const u8, what: []const u8 }{
        .{ .argv = &.{ "plugin", "install", "op" }, .what = "envee plugin install" },
        .{ .argv = &.{ "daemon", "start" }, .what = "envee daemon start" },
        .{ .argv = &.{ "daemon", "stop" }, .what = "envee daemon stop" },
        .{ .argv = &.{ "telemetry", "enable" }, .what = "envee telemetry enable" },
        .{ .argv = &.{"upgrade"}, .what = "envee upgrade" },
        .{ .argv = &.{"debug"}, .what = "envee debug" },
    };
    for (cases) |c| {
        errs.reset();
        try testing.expectError(error.VersionIncompatible, harness.run(a, tmp, c.argv, &.{}));
        const d = errs.take().?;
        try testing.expectEqual(errs.Code.e014, d.code);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} is not implemented yet", .{c.what}), d.summary);
        try testing.expect(d.hint.len > 0);
    }
    try testing.expectEqualStrings("telemetry: off (envee collects no telemetry)\n", try harness.run(a, tmp, &.{ "telemetry", "status" }, &.{}));
}
