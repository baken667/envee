//! Команды `envee trust` и `envee deny`, а также настоящая проверка доверия.
//!
//! Порт `internal/cli/trust.go` и `internal/cli/trustgate.go`.
//!
//! Всё, что здесь печатается, идёт в stderr: `envee trust` иногда вызывают
//! из скриптов, и сводка не должна попадать в подстановку команд оболочки.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const config = @import("../config.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const gopath = @import("../path.zig");
const store_mod = @import("../trust/store.zig");
const summary_mod = @import("../trust/summary.zig");

const Ctx = context.Ctx;

pub const Error = context.Error || store_mod.Error || error{
    /// Значение `--ttl` не разобралось.
    InvalidTtl,
    /// Ответить на вопрос некому: ввод не терминал и нет `--yes`.
    NotInteractive,
};

// ---- проверка доверия ------------------------------------------------------

/// Гейт поверх настоящего хранилища.
///
/// Проверяется КАЖДЫЙ файл, вложившийся в конфиг, а не только первый.
/// Разрешённый конфиг — это обычно склейка нескольких: envee.toml,
/// envee.local.toml, envee.d/*.toml, конфиги родительских каталогов и
/// глобальный. Проверить только первый значило бы позволить тому, кто может
/// писать в любой из остальных (envee.local.toml лежит в .gitignore,
/// envee.d — каталог для подкладывания фрагментов), внести переменные и
/// директивы, которых пользователь никогда не одобрял.
pub const Gate = struct {
    store: store_mod.Store,
    arena: Allocator,

    pub fn trustGate(g: *Gate) context.TrustGate {
        return .{ .ctx = g, .checkFn = check };
    }

    fn check(ctx: *anyopaque, sources: []const config.SourceFile) errs.Error!void {
        const g: *Gate = @ptrCast(@alignCast(ctx));
        for (sources) |src| {
            const st = g.store.status(g.arena, src.path, src.hash) catch store_mod.Status.unknown;
            if (st == .trusted) continue;
            return fail(st, src);
        }
    }

    fn fail(st: store_mod.Status, src: config.SourceFile) errs.Error {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{
            .{ .key = "path", .value = src.path },
            .{ .key = "hash", .value = src.hash },
        };
        return switch (st) {
            .denied => errs.fail(.{
                .code = .e010,
                .summary = "envee.toml is denied",
                .context = &S.kv,
                .hint = "Run `envee trust` to approve it instead.",
            }, error.TrustDenied),
            .expired => errs.fail(.{
                .code = .e001,
                .summary = "trust has expired",
                .context = &S.kv,
                .hint = "Run `envee trust` to renew it.",
            }, error.TrustRequired),
            else => errs.fail(.{
                .code = .e001,
                .summary = "envee.toml is not trusted",
                .context = &S.kv,
                .hint = "Run `envee trust` to review and approve its content.",
            }, error.TrustRequired),
        };
    }
};

// ---- команды ---------------------------------------------------------------

/// Что делать с конфигом по ответу пользователя.
pub const Answer = enum { grant, deny, show_diff, skip, quit };

/// Источник ответа. Отдельный тип, чтобы тесты не изображали терминал.
pub const Asker = struct {
    ctx: *anyopaque,
    askFn: *const fn (ctx: *anyopaque, question: []const u8) anyerror!Answer,

    pub fn ask(a: Asker, prompt: []const u8) anyerror!Answer {
        return a.askFn(a.ctx, prompt);
    }
};

/// Разбор ответа. Пустая строка — согласие: вопрос задан с заглавной Y.
/// Непонятный ответ тоже трактуется как согласие по умолчанию, как в Go.
pub fn parseAnswer(line: []const u8) Answer {
    var buf: [16]u8 = undefined;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return .grant;
    const lower = std.ascii.lowerString(buf[0..trimmed.len], trimmed);

    if (std.mem.eql(u8, lower, "y") or std.mem.eql(u8, lower, "yes")) return .grant;
    if (std.mem.eql(u8, lower, "n") or std.mem.eql(u8, lower, "no")) return .deny;
    if (std.mem.eql(u8, lower, "d") or std.mem.eql(u8, lower, "diff")) return .show_diff;
    if (std.mem.eql(u8, lower, "s") or std.mem.eql(u8, lower, "skip")) return .skip;
    if (std.mem.eql(u8, lower, "q") or std.mem.eql(u8, lower, "quit")) return .quit;
    return .grant;
}

const prompt_text = "Trust this file? [Y/n/d(iff)/s(kip)/q(uit)] ";

pub fn runTrust(ctx: *Ctx, parsed: args_mod.Parsed, asker: ?Asker) Error!void {
    const target = try targetPath(ctx, parsed);
    const store = storeFor(ctx);

    var diag: config.Diagnostics = .{};
    const cfg = config.parseFile(ctx.arena, ctx.io, target, &diag) catch |err| {
        return liftParseError(err, target, diag);
    };

    if (parsed.boolean("remove")) {
        try store.revoke(ctx.arena, cfg.file_hash);
        try ctx.stderr.print("[envee] trust revoked for {s} (hash {s})\n", .{ target, cfg.file_hash });
        return;
    }

    const summary = try summary_mod.build(ctx.arena, cfg);
    try summary_mod.write(ctx.stderr, summary);

    if (!parsed.boolean("yes")) {
        const a = asker orelse return error.NotInteractive;
        // Показ содержимого не завершает разговор: после него спрашиваем
        // снова, иначе пользователь остался бы без возможности ответить.
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const answer = a.ask(prompt_text) catch return error.NotInteractive;
            switch (answer) {
                .grant => break,
                .deny, .quit => {
                    try ctx.stderr.writeAll("[envee] trust not granted\n");
                    return;
                },
                .skip => {
                    try ctx.stderr.writeAll("[envee] skipped\n");
                    return;
                },
                .show_diff => {
                    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, target, ctx.arena, .unlimited) catch "";
                    try ctx.stderr.print("--- envee.toml ---\n{s}\n--- end ---\n", .{data});
                },
            }
        }
    }

    const ttl = store_mod.parseTtl(parsed.str("ttl")) orelse return error.InvalidTtl;
    const entry = try store.trust(ctx.arena, target, cfg.file_hash, ttl);

    try ctx.stderr.print("[envee] trusted {s}\n", .{target});
    try ctx.stderr.print("         hash:    {s}\n", .{cfg.file_hash});
    try ctx.stderr.print("         expires: {s}\n", .{
        if (entry.expires_at.len > 0) entry.expires_at else "never",
    });
}

pub fn runDeny(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const target = try targetPath(ctx, parsed);
    try storeFor(ctx).deny(ctx.arena, target);
    try ctx.stderr.print("[envee] denied {s}\n", .{target});
}

fn storeFor(ctx: *Ctx) store_mod.Store {
    return .{
        .root = ctx.paths.trust_store,
        .io = ctx.io,
        .now_ns = std.Io.Timestamp.now(ctx.io, .real).nanoseconds,
        .user = ctx.environ.get("USER") orelse (ctx.environ.get("USERNAME") orelse "unknown"),
        .tool_version = ctx.tool_version,
    };
}

/// Файл, о котором идёт речь: аргумент или `envee.toml` в текущем каталоге.
fn targetPath(ctx: *Ctx, parsed: args_mod.Parsed) Allocator.Error![]const u8 {
    if (parsed.args.len > 0) {
        if (std.fs.path.isAbsolute(parsed.args[0])) return parsed.args[0];
        return gopath.join(ctx.arena, &.{ ctx.cwd, parsed.args[0] });
    }
    return gopath.join(ctx.arena, &.{ ctx.cwd, "envee.toml" });
}

fn liftParseError(err: anyerror, path: []const u8, diag: config.Diagnostics) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.FileNotFound) {
        const S = struct {
            var kv: [1]errs.KV = undefined;
        };
        S.kv = .{.{ .key = "path", .value = path }};
        return errs.fail(.{
            .code = .e012,
            .summary = "envee.toml not found",
            .context = &S.kv,
            .hint = "Pass a path: envee trust path/to/envee.toml",
        }, error.FileNotFound);
    }
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

/// Задаёт вопрос на настоящем терминале.
pub const StdinAsker = struct {
    io: std.Io,
    out: *Writer,
    buf: [256]u8 = undefined,

    pub fn asker(s: *StdinAsker) Asker {
        return .{ .ctx = s, .askFn = ask };
    }

    fn ask(ctx: *anyopaque, q: []const u8) anyerror!Answer {
        const s: *StdinAsker = @ptrCast(@alignCast(ctx));
        try s.out.writeAll(q);
        try s.out.flush();

        var read_buf: [256]u8 = undefined;
        var reader: std.Io.File.Reader = .init(.stdin(), s.io, &read_buf);
        // Конец ввода — это не согласие. Молча одобрить конфиг потому, что
        // отвечать было некому, — ровно то, чего делать нельзя.
        const line = reader.interface.takeDelimiterExclusive('\n') catch return .quit;
        return parseAnswer(line);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

/// Отвечает заранее заданной последовательностью.
const ScriptedAsker = struct {
    answers: []const Answer,
    index: usize = 0,
    asked: usize = 0,

    fn asker(s: *ScriptedAsker) Asker {
        return .{ .ctx = s, .askFn = ask };
    }

    fn ask(ctx: *anyopaque, _: []const u8) anyerror!Answer {
        const s: *ScriptedAsker = @ptrCast(@alignCast(ctx));
        s.asked += 1;
        if (s.index >= s.answers.len) return .quit;
        defer s.index += 1;
        return s.answers[s.index];
    }
};

test "answer parsing" {
    try testing.expectEqual(Answer.grant, parseAnswer(""));
    try testing.expectEqual(Answer.grant, parseAnswer("\n"));
    try testing.expectEqual(Answer.grant, parseAnswer("y"));
    try testing.expectEqual(Answer.grant, parseAnswer("YES"));
    try testing.expectEqual(Answer.deny, parseAnswer("n"));
    try testing.expectEqual(Answer.deny, parseAnswer(" No "));
    try testing.expectEqual(Answer.show_diff, parseAnswer("d"));
    try testing.expectEqual(Answer.show_diff, parseAnswer("diff"));
    try testing.expectEqual(Answer.skip, parseAnswer("s"));
    try testing.expectEqual(Answer.quit, parseAnswer("q"));
    // Непонятный ответ — согласие по умолчанию, как в Go.
    try testing.expectEqual(Answer.grant, parseAnswer("maybe"));
}

test "trust approves, and eval then works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    // До одобрения eval отказывает.
    try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    const trust_out = try harness.runRealFull(a, tmp, &.{"trust"}, &.{}, yes.asker());
    try testing.expect(std.mem.indexOf(u8, trust_out.stderr, "Trust ") != null);
    try testing.expect(std.mem.indexOf(u8, trust_out.stderr, "[envee] trusted ") != null);
    try testing.expect(std.mem.indexOf(u8, trust_out.stderr, "expires: never") != null);
    // Сводка и подтверждение идут в stderr: stdout занят подстановкой команд.
    try testing.expectEqualStrings("", trust_out.stdout);

    // После одобрения — работает.
    const out = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }}, null);
    try testing.expect(std.mem.indexOf(u8, out, "export A=1;") != null);
}

// Одобрение привязано к содержимому: правка требует нового одобрения.
test "editing the config invalidates the approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes.asker());
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);

    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"2\"\n");
    try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));
}

// Переформатирование — не смысловое изменение, повторно одобрять его не надо.
test "reformatting does not invalidate the approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\nB = \"2\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes.asker());

    try tmp.write(a, "# a comment\nschema   =   'envee/v1'\n\n[env]\nB = \"2\"\nA = \"1\"\n");
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);
}

test "--yes approves without asking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var never: ScriptedAsker = .{ .answers = &.{} };
    _ = try harness.runReal(a, tmp, &.{ "trust", "--yes" }, &.{}, never.asker());
    try testing.expectEqual(@as(usize, 0), never.asked);
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);
}

// Отвечать некому и --yes не передан — одобрять нельзя.
test "a non-interactive run without --yes refuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    try testing.expectError(error.NotInteractive, harness.runReal(a, tmp, &.{"trust"}, &.{}, null));
    try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));
}

test "answering no leaves the config unapproved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    for ([_]Answer{ .deny, .quit, .skip }) |answer| {
        var scripted: ScriptedAsker = .{ .answers = &.{answer} };
        const out = try harness.runRealFull(a, tmp, &.{"trust"}, &.{}, scripted.asker());
        try testing.expect(std.mem.indexOf(u8, out.stderr, "[envee] trusted") == null);
        try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));
    }
}

// Показ содержимого не должен завершать разговор: иначе ответить было бы
// нельзя.
test "showing the file re-asks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nMARKER = \"in-the-file\"\n");

    var scripted: ScriptedAsker = .{ .answers = &.{ .show_diff, .grant } };
    const out = try harness.runRealFull(a, tmp, &.{"trust"}, &.{}, scripted.asker());

    try testing.expectEqual(@as(usize, 2), scripted.asked);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "MARKER = \"in-the-file\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "[envee] trusted") != null);
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);
}

test "a TTL is recorded and eventually expires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    const out = try harness.runRealFull(a, tmp, &.{ "trust", "--ttl", "24h" }, &.{}, yes.asker());
    // Срок печатается, чтобы пользователь видел, когда придётся повторить.
    try testing.expect(std.mem.indexOf(u8, out.stderr, "expires: 2") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "expires: never") == null);
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);

    try testing.expectError(error.InvalidTtl, harness.runReal(a, tmp, &.{ "trust", "--yes", "--ttl", "nonsense" }, &.{}, null));
}

test "deny blocks, and stays blocking after an edit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes.asker());
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);

    const out = try harness.runRealFull(a, tmp, &.{"deny"}, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "[envee] denied") != null);

    errs.reset();
    try testing.expectError(error.TrustDenied, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e010, d.code);
    try testing.expectEqual(@as(u8, 3), d.exitCode());

    // Правка запрет не снимает.
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"2\"\n");
    try testing.expectError(error.TrustDenied, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));

    // А повторное одобрение — снимает.
    var yes2: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes2.asker());
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);
}

test "--remove revokes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes.asker());
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);

    const out = try harness.runRealFull(a, tmp, &.{ "trust", "--remove" }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "trust revoked") != null);
    try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));
}

// Одобрение одного файла не должно распространяться на остальные: иначе тот,
// кто может писать в envee.local.toml или envee.d/, внёс бы что угодно.
test "every contributing file must be approved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{"trust"}, &.{}, yes.asker());
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);

    // Появился второй файл — его никто не одобрял.
    try tmp.writeFile(a, "envee.local.toml", "schema = \"envee/v1\"\n[env]\nSNEAKY = \"injected\"\n");
    try testing.expectError(error.TrustRequired, harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null));

    // Одобряем и его — теперь работает.
    var yes2: ScriptedAsker = .{ .answers = &.{.grant} };
    _ = try harness.runReal(a, tmp, &.{ "trust", "envee.local.toml" }, &.{}, yes2.asker());
    const out = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{.{ "PATH", "/usr/bin" }}, null);
    try testing.expect(std.mem.indexOf(u8, out, "SNEAKY") != null);
}

test "trust accepts an explicit path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.writeFile(a, "other.toml", "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    var yes: ScriptedAsker = .{ .answers = &.{.grant} };
    const path = try tmp.join(a, "other.toml");
    const out = try harness.runRealFull(a, tmp, &.{ "trust", path }, &.{}, yes.asker());
    try testing.expect(std.mem.indexOf(u8, out.stderr, "other.toml") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "[envee] trusted") != null);
}

test "trusting a missing file reports it clearly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.FileNotFound, harness.runReal(a, tmp, &.{ "trust", "--yes" }, &.{}, null));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e012, d.code);
}
