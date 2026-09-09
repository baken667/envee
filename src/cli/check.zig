//! Команда `envee check` — статический анализ `envee.toml`.
//!
//! Порт `internal/cli/check_impl.go`.
//!
//! Директивы НЕ применяются: не запускается ни один плагин, ни один скрипт,
//! ни один файл не подключается. `check` — это то, что запускают ПЕРЕД
//! одобрением конфига, поэтому побочных эффектов у него быть не должно.
//! Отсюда же и поиск плагинов через `$PATH`, а не через реестр: реестр
//! спрашивает у каждого плагина метаданные, то есть запускает его.
//!
//! ВНИМАНИЕ, отличие от Go-версии по ПОВЕДЕНИЮ. Там поиск циклов в шаблонах
//! шёл по регулярному выражению `\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(\||\}\})`,
//! которое не соответствует записи `{{env.A}}` из-за точки. То есть `check`
//! молчал ровно на той форме, которая документирована и используется во всех
//! примерах, а `eval` на ней же падал с E007. Здесь ссылки достаются тем же
//! разбором, что и при вычислении, поэтому обе формы видны.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const config = @import("../config.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const resolver_mod = @import("../resolver.zig");
const template = @import("../template.zig");

const Ctx = context.Ctx;

pub const Level = enum {
    err,
    warning,

    pub fn name(l: Level) []const u8 {
        return switch (l) {
            .err => "error",
            .warning => "warning",
        };
    }
};

pub const Finding = struct {
    level: Level,
    file: []const u8,
    /// Переменная, к которой относится замечание; пусто — ко всему файлу.
    key: []const u8 = "",
    message: []const u8,
    hint: []const u8 = "",
};

pub const Error = context.Error || error{CheckFailed};

/// Похоже ли имя переменной на имя учётных данных.
///
/// Совпадает с регулярным выражением Go-версии:
/// `(?i)(^|_)(KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIALS?|PRIVATE)(_|$)`,
/// то есть слово целиком, отделённое подчёркиванием или границей имени.
/// Поэтому `MONKEY` не срабатывает, а `API_KEY` — срабатывает.
pub fn looksLikeCredential(key: []const u8) bool {
    const words = [_][]const u8{
        "KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL", "CREDENTIALS", "PRIVATE",
    };
    var buf: [256]u8 = undefined;
    if (key.len > buf.len) return false;
    const upper = std.ascii.upperString(buf[0..key.len], key);

    for (words) |word| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, upper, from, word)) |at| {
            from = at + 1;
            const before_ok = at == 0 or upper[at - 1] == '_';
            const end = at + word.len;
            const after_ok = end == upper.len or upper[end] == '_';
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

/// Статически анализирует один разобранный конфиг.
///
/// `known_plugins` — имена источников, для которых плагин нашёлся в `$PATH`;
/// пустой срез означает «не проверяли».
pub fn checkConfig(
    arena: Allocator,
    io: std.Io,
    cfg: config.Config,
    known_plugins: ?[]const []const u8,
    strict: bool,
) Allocator.Error![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    const root_dir = gopath.dirname(arena, cfg.path) catch cfg.path;

    if (cfg.schema.len > 0 and !std.mem.eql(u8, cfg.schema, config.schema_version)) {
        try out.append(arena, .{
            .level = .err,
            .file = cfg.path,
            .message = try std.fmt.allocPrint(
                arena,
                "unknown schema \"{s}\" (this build understands \"{s}\")",
                .{ cfg.schema, config.schema_version },
            ),
            .hint = "Upgrade envee, or pin schema = \"" ++ config.schema_version ++ "\".",
        });
    }

    // Путь с шаблоном без применения директив разрешить нельзя, поэтому он
    // считается существующим — иначе check ругался бы на каждый
    // `{{config_root}}/bin`.
    const resolvePath = struct {
        fn f(a: Allocator, dir: []const u8, p: []const u8) []const u8 {
            if (std.fs.path.isAbsolute(p) or std.mem.indexOf(u8, p, "{{") != null) return p;
            return gopath.join(a, &.{ dir, p }) catch p;
        }
    }.f;
    const exists = struct {
        fn f(the_io: std.Io, full: []const u8) bool {
            // Путь с шаблоном без применения директив не разрешить, поэтому
            // он считается существующим — иначе check ругался бы на каждый
            // `{{config_root}}/bin`.
            if (std.mem.indexOf(u8, full, "{{") != null) return true;
            _ = std.Io.Dir.cwd().statFile(the_io, full, .{}) catch return false;
            return true;
        }
    }.f;

    // _.file — отсутствие файла ошибка только когда он объявлен обязательным.
    for (cfg.directives.file) |ref| {
        const full = resolvePath(arena, root_dir, ref.path);
        if (exists(io, full)) continue;
        if (ref.required) {
            try out.append(arena, .{
                .level = .err,
                .file = cfg.path,
                .message = try std.fmt.allocPrint(arena, "_.file references a missing file: {s}", .{ref.path}),
                // В подсказке — полный путь: чтобы создать файл, нужно
                // знать, где именно его ждут.
                .hint = try std.fmt.allocPrint(arena, "Create {s} or drop required = true.", .{full}),
            });
        } else if (strict) {
            // Отсутствующий необязательный файл — это ровно то, для чего
            // существует required = false, и в обычном режиме шум.
            try out.append(arena, .{
                .level = .warning,
                .file = cfg.path,
                .message = try std.fmt.allocPrint(arena, "optional _.file is absent: {s}", .{ref.path}),
                .hint = "It will be skipped at eval time. This is what required = false is for.",
            });
        }
    }

    // _.script и _.source пропустить нельзя, поэтому их отсутствие — ошибка.
    for (cfg.directives.script) |ref| {
        if (exists(io, resolvePath(arena, root_dir, ref.path))) continue;
        try out.append(arena, .{
            .level = .err,
            .file = cfg.path,
            .message = try std.fmt.allocPrint(arena, "_.script references a missing file: {s}", .{ref.path}),
        });
    }
    for (cfg.directives.source) |ref| {
        if (exists(io, resolvePath(arena, root_dir, ref.path))) continue;
        try out.append(arena, .{
            .level = .err,
            .file = cfg.path,
            .message = try std.fmt.allocPrint(arena, "_.source references a missing file: {s}", .{ref.path}),
        });
    }

    // Каталоги вроде node_modules/.bin законно появляются только после
    // сборки, поэтому это замечание только для --strict.
    if (strict) {
        for (cfg.directives.path) |ref| {
            if (exists(io, resolvePath(arena, root_dir, ref.path))) continue;
            try out.append(arena, .{
                .level = .warning,
                .file = cfg.path,
                .message = try std.fmt.allocPrint(arena, "_.path entry does not exist: {s}", .{ref.path}),
            });
        }
    }

    // Секреты — в обеих записях сразу, потому что применение поднимает
    // сокращённую форму, и check обязан понимать её так же.
    const secrets = try cfg.secretRefs(arena);
    const sorted = try arena.dupe(config.NamedSecret, secrets);
    std.mem.sort(config.NamedSecret, sorted, {}, lessThanSecret);

    for (sorted) |s| {
        if (s.ref.source.len == 0) {
            try out.append(arena, .{
                .level = .err,
                .file = cfg.path,
                .key = s.name,
                .message = "secret is missing 'source'",
            });
            continue;
        }
        if (s.ref.ref.len == 0) {
            try out.append(arena, .{
                .level = .err,
                .file = cfg.path,
                .key = s.name,
                .message = "secret is missing 'ref'",
            });
        }
        if (known_plugins) |known| {
            if (!containsString(known, s.ref.source)) {
                try out.append(arena, .{
                    .level = .warning,
                    .file = cfg.path,
                    .key = s.name,
                    .message = try std.fmt.allocPrint(arena, "no plugin found for secret source {s}", .{s.ref.source}),
                    .hint = try std.fmt.allocPrint(
                        arena,
                        "Install envee-plugin-{s} and make sure it is on $PATH.",
                        .{s.ref.source},
                    ),
                });
            }
        }
        if (!s.ref.redact) {
            try out.append(arena, .{
                .level = .warning,
                .file = cfg.path,
                .key = s.name,
                .message = "secret is not marked redact = true",
                .hint = "Its value will be printed in full by `envee status` and `envee diff`.",
            });
        }
    }

    // Пространство имён envee и гигиена учётных данных.
    for (cfg.env.keys(), cfg.env.map.values()) |k, v| {
        if (std.mem.eql(u8, k, "_")) continue;

        if (std.mem.startsWith(u8, k, "ENVEE_")) {
            try out.append(arena, .{
                .level = .err,
                .file = cfg.path,
                .key = k,
                .message = "config may not set reserved ENVEE_* variables",
                .hint = "These configure envee itself and are rejected at eval time.",
            });
            continue;
        }
        var is_secret = false;
        for (secrets) |s| {
            if (std.mem.eql(u8, s.name, k)) is_secret = true;
        }
        if (is_secret) continue;

        if (looksLikeCredential(k) and !isRedacted(v)) {
            try out.append(arena, .{
                .level = .warning,
                .file = cfg.path,
                .key = k,
                .message = "looks like a credential but is a plaintext literal",
                .hint = try std.fmt.allocPrint(
                    arena,
                    "Use [env._.secret.{s}] with a plugin, or set redact = true.",
                    .{k},
                ),
            });
        }
    }

    if (try findTemplateCycle(arena, cfg)) |cycle| {
        try out.append(arena, .{
            .level = .err,
            .file = cfg.path,
            .message = try std.fmt.allocPrint(arena, "circular template reference: {s}", .{cycle}),
            .hint = "Break the cycle; templates are resolved in dependency order.",
        });
    }

    return out.toOwnedSlice(arena);
}

fn lessThanSecret(_: void, a: config.NamedSecret, b: config.NamedSecret) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn containsString(list: []const []const u8, want: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, want)) return true;
    }
    return false;
}

/// Значение в `[env]` считается скрытым, если это inline-таблица с
/// `redact = true` либо ссылка на секрет.
fn isRedacted(v: config.Value) bool {
    const t = v.asTable() orelse return false;
    if (t.get("redact")) |r| {
        if (r.asBool() orelse false) return true;
    }
    if (t.get("source")) |s| {
        const source: []const u8 = s.asString() orelse "";
        return source.len > 0;
    }
    return false;
}

/// Ищет цикл среди переменных, ссылающихся друг на друга через шаблоны.
///
/// Ссылки достаются тем же разбором, что и при вычислении, поэтому видны обе
/// формы: и `{{ B }}`, и `{{env.B}}`. Go смотрел только на первую и потому
/// молчал на второй — той самой, что документирована.
const VisitState = enum { white, grey, black };

fn findTemplateCycle(arena: Allocator, cfg: config.Config) Allocator.Error!?[]const u8 {
    var state: std.StringArrayHashMapUnmanaged(VisitState) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;

    for (cfg.env.keys()) |k| try state.put(arena, k, .white);

    for (cfg.env.keys()) |k| {
        if (state.get(k).? != .white) continue;
        stack.clearRetainingCapacity();
        if (try walk(arena, cfg, k, &state, &stack)) |cycle| return cycle;
    }
    return null;
}

fn walk(
    arena: Allocator,
    cfg: config.Config,
    key: []const u8,
    state: *std.StringArrayHashMapUnmanaged(VisitState),
    stack: *std.ArrayList([]const u8),
) Allocator.Error!?[]const u8 {
    try state.put(arena, key, .grey);
    try stack.append(arena, key);

    const text = if (cfg.env.get(key)) |v| (v.asString() orelse "") else "";
    for (try template.extractVarRefs(arena, text)) |dep| {
        // Ссылки наружу (переменные окружения) циклом быть не могут.
        const dep_state = state.get(dep) orelse continue;
        switch (dep_state) {
            .grey => {
                var out: std.ArrayList(u8) = .empty;
                for (stack.items) |s| {
                    if (out.items.len > 0) try out.appendSlice(arena, " -> ");
                    try out.appendSlice(arena, s);
                }
                try out.appendSlice(arena, " -> ");
                try out.appendSlice(arena, dep);
                return try out.toOwnedSlice(arena);
            },
            .white => {
                if (try walk(arena, cfg, dep, state, stack)) |cycle| return cycle;
            },
            .black => {},
        }
    }

    _ = stack.pop();
    try state.put(arena, key, .black);
    return null;
}

/// Для каждого источника секретов проверяет, есть ли `envee-plugin-<источник>`
/// в `$PATH`.
///
/// Именно поиск по PATH, а не через реестр плагинов: реестр запускает каждый
/// плагин, чтобы спросить метаданные, а `check` обязан быть безопасен для
/// ещё не одобренного конфига.
fn pluginsOnPath(arena: Allocator, io: std.Io, cfg: config.Config, path_var: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const secrets = try cfg.secretRefs(arena);

    for (secrets) |s| {
        if (s.ref.source.len == 0 or containsString(out.items, s.ref.source)) continue;
        const exe = try std.fmt.allocPrint(arena, "envee-plugin-{s}", .{s.ref.source});

        var it = std.mem.splitScalar(u8, path_var, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = gopath.join(arena, &.{ dir, exe }) catch continue;
            _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
            try out.append(arena, s.ref.source);
            break;
        }
    }
    return out.toOwnedSlice(arena);
}

// ---- команда ---------------------------------------------------------------

pub fn run(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    return runWithStopAt(ctx, parsed, "");
}

pub fn runWithStopAt(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const strict = parsed.boolean("strict");
    const json_out = parsed.boolean("json");

    var configs: std.ArrayList(config.Config) = .empty;

    if (parsed.args.len == 1) {
        var diag: config.Diagnostics = .{};
        const cfg = config.parseFile(ctx.arena, ctx.io, parsed.args[0], &diag) catch |err| {
            return liftParseError(err, parsed.args[0], diag);
        };
        try configs.append(ctx.arena, cfg);
    } else if (parsed.str("config").len > 0) {
        const p = parsed.str("config");
        var diag: config.Diagnostics = .{};
        const cfg = config.parseFile(ctx.arena, ctx.io, p, &diag) catch |err| {
            return liftParseError(err, p, diag);
        };
        try configs.append(ctx.arena, cfg);
    } else {
        // Без аргумента проверяются все файлы, которые загрузил бы resolver.
        // Доверие при этом не требуется: проверка — это то, что делают ДО
        // одобрения.
        var r = resolver_mod.Resolver.init(ctx.cwd, ctx.paths);
        r.profile = context.activeProfile(ctx, parsed.str("profile"));
        r.stop_at_root = stop_at;

        const files = try r.discover(ctx.arena, ctx.io);
        if (files.len == 0) {
            const S = struct {
                var kv: [1]errs.KV = undefined;
            };
            S.kv = .{.{ .key = "dir", .value = ctx.cwd }};
            return errs.fail(.{
                .code = .e003,
                .summary = "no envee.toml found",
                .context = &S.kv,
                .hint = "Create an envee.toml, or pass a path: envee check path/to/envee.toml",
            }, error.ConfigValidation);
        }
        for (files) |f| {
            var diag: config.Diagnostics = .{};
            const cfg = config.parseFile(ctx.arena, ctx.io, f, &diag) catch |err| {
                return liftParseError(err, f, diag);
            };
            try configs.append(ctx.arena, cfg);
        }
    }

    var found: std.ArrayList(Finding) = .empty;
    const path_var = ctx.os_env.get("PATH") orelse (ctx.environ.get("PATH") orelse "");
    for (configs.items) |cfg| {
        const known = try pluginsOnPath(ctx.arena, ctx.io, cfg, path_var);
        try found.appendSlice(ctx.arena, try checkConfig(ctx.arena, ctx.io, cfg, known, strict));
    }

    var errors: usize = 0;
    var warnings: usize = 0;
    for (found.items) |f| {
        if (f.level == .err) errors += 1 else warnings += 1;
    }
    const ok = errors == 0 and (!strict or warnings == 0);

    if (json_out) {
        try writeJsonReport(ctx.stdout, configs.items, found.items, errors, warnings, ok);
    } else {
        for (configs.items) |cfg| try ctx.stdout.print("checking {s}\n", .{cfg.path});
        if (found.items.len == 0) {
            try ctx.stdout.writeAll("no problems found\n");
        } else {
            try writeFindings(ctx.stdout, found.items);
            try ctx.stdout.print("\n{d} error(s), {d} warning(s)\n", .{ errors, warnings });
        }
    }

    if (!ok) {
        const S = struct {
            var kv: [2]errs.KV = undefined;
            var err_buf: [24]u8 = undefined;
            var warn_buf: [24]u8 = undefined;
        };
        S.kv = .{
            .{ .key = "errors", .value = std.fmt.bufPrint(&S.err_buf, "{d}", .{errors}) catch "?" },
            .{ .key = "warnings", .value = std.fmt.bufPrint(&S.warn_buf, "{d}", .{warnings}) catch "?" },
        };
        return errs.fail(.{
            .code = .e003,
            .summary = "config check failed",
            .context = &S.kv,
        }, error.ConfigValidation);
    }
}

fn liftParseError(err: anyerror, path: []const u8, diag: config.Diagnostics) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const S = struct {
        var kv: [4]errs.KV = undefined;
        var line_buf: [24]u8 = undefined;
        var col_buf: [24]u8 = undefined;
    };
    S.kv = .{
        .{ .key = "path", .value = path },
        .{ .key = "line", .value = std.fmt.bufPrint(&S.line_buf, "{d}", .{diag.line}) catch "?" },
        .{ .key = "column", .value = std.fmt.bufPrint(&S.col_buf, "{d}", .{diag.column}) catch "?" },
        .{ .key = "detail", .value = if (diag.detail.len > 0) diag.detail else @errorName(err) },
    };
    return errs.fail(.{
        .code = .e002,
        .summary = "failed to parse envee.toml",
        .context = &S.kv,
        .hint = "Check TOML syntax at the indicated line.",
    }, error.ConfigParse);
}

fn writeFindings(w: *Writer, list: []const Finding) Writer.Error!void {
    for (list) |f| {
        var upper_buf: [16]u8 = undefined;
        const level = std.ascii.upperString(upper_buf[0..f.level.name().len], f.level.name());
        try w.print("  {s}", .{level});
        // Колонка уровня шириной 7, как в Go («%-7s»).
        if (level.len < 7) try w.splatByteAll(' ', 7 - level.len);
        try w.print(" {s}", .{f.file});
        if (f.key.len > 0) try w.print(": {s}", .{f.key});
        try w.print("\n           {s}\n", .{f.message});
        if (f.hint.len > 0) try w.print("           hint: {s}\n", .{f.hint});
    }
}

fn writeJsonReport(
    w: *Writer,
    configs: []const config.Config,
    list: []const Finding,
    errors: usize,
    warnings: usize,
    ok: bool,
) Writer.Error!void {
    try w.writeAll("{\n  \"files\": [");
    for (configs, 0..) |cfg, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n    ");
        try std.json.Stringify.value(cfg.path, .{}, w);
    }
    try w.writeAll(if (configs.len > 0) "\n  ],\n" else "],\n");

    try w.writeAll("  \"findings\": [");
    for (list, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n    {\n      \"level\": ");
        try std.json.Stringify.value(f.level.name(), .{}, w);
        try w.writeAll(",\n      \"file\": ");
        try std.json.Stringify.value(f.file, .{}, w);
        if (f.key.len > 0) {
            try w.writeAll(",\n      \"key\": ");
            try std.json.Stringify.value(f.key, .{}, w);
        }
        try w.writeAll(",\n      \"message\": ");
        try std.json.Stringify.value(f.message, .{}, w);
        if (f.hint.len > 0) {
            try w.writeAll(",\n      \"hint\": ");
            try std.json.Stringify.value(f.hint, .{}, w);
        }
        try w.writeAll("\n    }");
    }
    try w.writeAll(if (list.len > 0) "\n  ],\n" else "],\n");

    try w.print("  \"errors\": {d},\n  \"warnings\": {d},\n  \"ok\": {}\n}}\n", .{ errors, warnings, ok });
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

fn analyse(gpa: Allocator, dir: harness.TempDir, body: []const u8, strict: bool) ![]const Finding {
    try dir.write(gpa, body);
    const path = try dir.join(gpa, "envee.toml");
    const cfg = try config.parseFile(gpa, std.testing.io, path, null);
    return checkConfig(gpa, std.testing.io, cfg, null, strict);
}

fn has(list: []const Finding, level: Level, substr: []const u8) bool {
    for (list) |f| {
        if (f.level == level and std.mem.indexOf(u8, f.message, substr) != null) return true;
    }
    return false;
}

test "a missing required file is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\A = "1"
        \\_.file = [ { path = "nope.env", required = true } ]
    , false);
    try testing.expect(has(got, .err, "nope.env"));
}

// Отсутствующий необязательный файл — это ровно то, для чего существует
// required = false, поэтому по умолчанию о нём молчат.
test "an absent optional file is quiet unless strict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const body =
        \\schema = "envee/v1"
        \\[env]
        \\_.file = [ { path = ".env.local", required = false } ]
    ;
    try testing.expectEqual(@as(usize, 0), (try analyse(a, tmp, body, false)).len);
    try testing.expect(has(try analyse(a, tmp, body, true), .warning, ".env.local"));
}

test "reserved keys are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp, "schema = \"envee/v1\"\n[env]\nENVEE_BYPASS_TRUST = \"1\"\n", false);
    try testing.expect(has(got, .err, "reserved"));
}

test "template cycles are found in both spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const bare = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\A = "{{ B }}"
        \\B = "{{ C }}"
        \\C = "{{ A }}"
    , false);
    try testing.expect(has(bare, .err, "circular"));

    // Форма env.X — документированная, она во всех примерах. Go её не видел:
    // его регулярное выражение спотыкалось о точку, и check молчал о конфиге,
    // который eval отвергает.
    const dotted = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\A = "{{env.B}}"
        \\B = "{{env.A}}"
    , false);
    try testing.expect(has(dotted, .err, "circular"));
}

test "acyclic templates are accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\A = "root"
        \\B = "{{ A }}/sub"
        \\C = "{{ B }}/leaf"
    , false);
    try testing.expect(!has(got, .err, "circular"));

    // Ссылка на переменную окружения циклом не является.
    const external = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\A = "{{env.HOME}}/x"
    , false);
    try testing.expect(!has(external, .err, "circular"));
}

test "a plaintext credential is flagged, a benign name is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\STRIPE_SECRET_KEY = "sk_live_totally_real"
        \\SERVICE_NAME = "myapp"
    , false);
    try testing.expect(has(got, .warning, "credential"));
    for (got) |f| try testing.expect(!std.mem.eql(u8, f.key, "SERVICE_NAME"));
}

test "a redacted credential is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env]
        \\API_KEY = { value = "dev-only", redact = true }
    , false);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "credential detection matches whole words only" {
    // Слово целиком, отделённое подчёркиванием или границей имени.
    for ([_][]const u8{ "API_KEY", "KEY", "key", "DB_PASSWORD", "GITHUB_TOKEN", "MY_SECRET_X", "PRIVATE_KEY", "AWS_CREDENTIALS" }) |k| {
        testing.expect(looksLikeCredential(k)) catch {
            std.debug.print("looksLikeCredential({s}) = false, want true\n", .{k});
            return error.TestExpectedEqual;
        };
    }
    for ([_][]const u8{ "MONKEY", "SERVICE_NAME", "PORT", "KEYBOARD", "TOKENIZER", "DATABASE_URL" }) |k| {
        testing.expect(!looksLikeCredential(k)) catch {
            std.debug.print("looksLikeCredential({s}) = true, want false\n", .{k});
            return error.TestExpectedEqual;
        };
    }
}

test "an unknown schema is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp, "schema = \"envee/v99\"\n[env]\nA = \"1\"\n", false);
    try testing.expect(has(got, .err, "unknown schema"));
}

test "a missing secret plugin is a warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\schema = "envee/v1"
        \\[env]
        \\DB_PASSWORD = { source = "vault", ref = "secret/data/db#password", redact = true }
    );
    const cfg = try config.parseFile(a, std.testing.io, try tmp.join(a, "envee.toml"), null);

    const absent = try checkConfig(a, std.testing.io, cfg, @as([]const []const u8, &.{}), false);
    try testing.expect(has(absent, .warning, "no plugin found"));

    const present = try checkConfig(a, std.testing.io, cfg, @as([]const []const u8, &.{"vault"}), false);
    try testing.expectEqual(@as(usize, 0), present.len);
}

test "a secret without redact is a warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const got = try analyse(a, tmp,
        \\schema = "envee/v1"
        \\[env._.secret.DB]
        \\source = "vault"
        \\ref = "r"
    , false);
    try testing.expect(has(got, .warning, "not marked redact"));
}

test "check reports a clean config and exits successfully" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const out = try harness.run(a, tmp, &.{"check"}, &.{});
    try testing.expect(std.mem.indexOf(u8, out, "checking ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "no problems found") != null);
}

// check запускают ДО одобрения конфига, поэтому доверия он не требует.
test "check does not require trust" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const out = try harness.runUntrusted(a, tmp, &.{"check"}, &.{});
    try testing.expect(std.mem.indexOf(u8, out, "no problems found") != null);
}

test "a failing check exits with the config error code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nENVEE_X = \"1\"\n");

    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{"check"}, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e003, d.code);
    try testing.expectEqual(@as(u8, 4), d.exitCode());
}

test "check --json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nSTRIPE_SECRET_KEY = \"sk_live\"\n");

    const out = try harness.run(a, tmp, &.{ "check", "--json" }, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("errors").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("warnings").?.integer);
    try testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("files").?.array.items.len);

    const f = parsed.value.object.get("findings").?.array.items[0].object;
    try testing.expectEqualStrings("warning", f.get("level").?.string);
    try testing.expectEqualStrings("STRIPE_SECRET_KEY", f.get("key").?.string);
    try testing.expect(f.get("hint") != null);
}

test "check --json on a clean config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const out = try harness.run(a, tmp, &.{ "check", "--json" }, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("findings").?.array.items.len);
    try testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
}

// --strict превращает предупреждения в повод для ненулевого кода возврата.
test "strict turns warnings into failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nSTRIPE_SECRET_KEY = \"sk_live\"\n");

    _ = try harness.run(a, tmp, &.{"check"}, &.{});
    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{ "check", "--strict" }, &.{}));
}

test "check accepts an explicit path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.writeFile(a, "other.toml", "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const path = try tmp.join(a, "other.toml");
    const out = try harness.run(a, tmp, &.{ "check", path }, &.{});
    try testing.expect(std.mem.indexOf(u8, out, "other.toml") != null);
    try testing.expect(std.mem.indexOf(u8, out, "no problems found") != null);
}

test "check on a broken file reports the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\nbroken = = =\n");

    errs.reset();
    try testing.expectError(error.ConfigParse, harness.run(a, tmp, &.{"check"}, &.{}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e002, d.code);
    try testing.expectEqualStrings("2", d.context[1].value);
}

// Все примеры репозитория обязаны проходить проверку: это витрина проекта.
test "every example config passes check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var dir = std.Io.Dir.cwd().openDir(io, "examples", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var found: usize = 0;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".toml")) continue;

        const path = try gopath.join(a, &.{ "examples", entry.path });
        const cfg = try config.parseFile(a, io, path, null);
        const got = try checkConfig(a, io, cfg, null, false);
        for (got) |f| {
            if (f.level != .err) continue;
            std.debug.print("{s}: {s}\n", .{ path, f.message });
            return error.TestUnexpectedResult;
        }
        found += 1;
    }
    try testing.expect(found >= 4);
}
