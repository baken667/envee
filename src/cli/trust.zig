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
const sign_mod = @import("../trust/sign.zig");
const ssh_key = @import("../trust/ssh_key.zig");
const store_mod = @import("../trust/store.zig");
const summary_mod = @import("../trust/summary.zig");

const Ctx = context.Ctx;

pub const Error = context.Error || store_mod.Error || sign_mod.Error || ssh_key.Error || error{
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
    // Импорт чужого одобрения — отдельный путь: свой конфиг тут не читается.
    if (parsed.str("from").len > 0) return runImport(ctx, parsed);

    try approve(ctx, parsed, asker);
    if (parsed.str("export").len > 0) try runExport(ctx, parsed);
}

fn approve(ctx: *Ctx, parsed: args_mod.Parsed, asker: ?Asker) Error!void {
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

    const want_sign = parsed.boolean("sign") or parsed.str("key").len > 0;

    // Подпись подразумевает, что решение уже принято: рецензент подписывает
    // то, что прочитал. Как и в Go, вопрос снимает `--sign`, но не `--key`
    // сам по себе: путь к ключу лишь уточняет, чем подписывать.
    if (!parsed.boolean("yes") and !parsed.boolean("sign")) {
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

    // Сначала собрать запись, потом подписать, потом сохранить один раз.
    // Сохранить до подписи значило бы оставить неподписанную запись, если
    // подпись не удалась.
    var entry = try store.newEntry(ctx.arena, target, cfg.file_hash, ttl);
    if (want_sign) try signWithKey(ctx, &entry, parsed.str("key"));
    try store.put(ctx.arena, entry);

    try ctx.stderr.print("[envee] trusted {s}\n", .{target});
    try ctx.stderr.print("         hash:    {s}\n", .{cfg.file_hash});
    try ctx.stderr.print("         expires: {s}\n", .{
        if (store_mod.hasExpiry(entry)) entry.expires_at else "never",
    });
    if (entry.signature) |sig| {
        try ctx.stderr.print("         signed:  {s} (key {s})\n", .{ sig.algorithm, sig.key_id });
    }
}

/// Подписывает запись ключом `--key` либо `~/.ssh/id_ed25519`.
///
/// Любой другой ключ по умолчанию не берётся: неоднозначность здесь стоит
/// дороже, чем просьба назвать ключ явно.
fn signWithKey(ctx: *Ctx, entry: *store_mod.Entry, key_flag: []const u8) Error!void {
    const key_path = if (key_flag.len > 0) key_flag else defaultSigningKey(ctx) orelse {
        return errs.fail(.{
            .code = .e003,
            .summary = "no signing key found",
            .hint = "Pass --key PATH, or create one with: ssh-keygen -t ed25519",
        }, error.ConfigValidation);
    };

    const secret = ssh_key.loadPrivateKey(ctx.arena, ctx.io, key_path) catch |err| {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{
            .{ .key = "key", .value = key_path },
            .{ .key = "detail", .value = @errorName(err) },
        };
        return errs.fail(.{
            .code = .e013,
            .summary = "cannot use signing key",
            .context = &S.kv,
            .hint = switch (err) {
                error.PassphraseProtected => "The key is passphrase-protected; envee cannot prompt for it. Use an unencrypted key, or decrypt it into a temporary file.",
                error.NotEd25519 => "Only ed25519 keys are accepted. Generate one with: ssh-keygen -t ed25519",
                else => "Expected an OpenSSH private key, e.g. ~/.ssh/id_ed25519.",
            },
        }, error.PermissionDenied);
    };
    const now = try store_mod.formatRfc3339(ctx.arena, std.Io.Timestamp.now(ctx.io, .real).nanoseconds);
    try sign_mod.signEntry(ctx.arena, entry, secret, now);
}

fn defaultSigningKey(ctx: *Ctx) ?[]const u8 {
    const home = ctx.environ.get("HOME") orelse return null;
    const candidate = std.fs.path.join(ctx.arena, &.{ home, ".ssh", "id_ed25519" }) catch return null;
    _ = std.Io.Dir.cwd().statFile(ctx.io, candidate, .{}) catch return null;
    return candidate;
}

/// Записывает сохранённое одобрение в файл, чтобы передать его другому.
/// Полезно только вместе с `--sign`: без подписи получателю нечего проверять.
fn runExport(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const target = try targetPath(ctx, parsed);
    const dest = parsed.str("export");

    var diag: config.Diagnostics = .{};
    const cfg = config.parseFile(ctx.arena, ctx.io, target, &diag) catch |err| {
        return liftParseError(err, target, diag);
    };
    const entry = (try storeFor(ctx).get(ctx.arena, cfg.file_hash)) orelse {
        const S = struct {
            var kv: [1]errs.KV = undefined;
        };
        S.kv = .{.{ .key = "path", .value = target }};
        return errs.fail(.{
            .code = .e001,
            .summary = "nothing to export: this config is not trusted",
            .context = &S.kv,
        }, error.TrustRequired);
    };
    if (entry.signature == null) {
        try ctx.stderr.writeAll("[envee] WARN: exporting an unsigned entry — a recipient cannot verify it. " ++
            "Re-run with --sign to make it shareable.\n");
    }

    var body: Writer.Allocating = .init(ctx.arena);
    store_mod.writeEntryJson(&body.writer, entry) catch return error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = body.written() }) catch |err| {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{
            .{ .key = "path", .value = dest },
            .{ .key = "detail", .value = @errorName(err) },
        };
        return errs.fail(.{ .code = .e013, .summary = "cannot write the exported entry", .context = &S.kv }, error.PermissionDenied);
    };
    try ctx.stderr.print("[envee] exported trust entry to {s}\n", .{dest});
}

/// Проверяет чужое одобрение по публичному ключу и, только если оно
/// сходится, кладёт в своё хранилище.
///
/// Подпись — то, что делает это безопасным: без проверки это был бы способ
/// одобрять конфиги от чужого имени.
fn runImport(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const from = parsed.str("from");
    const public_key_path = parsed.str("public-key");
    if (public_key_path.len == 0) {
        return errs.fail(.{
            .code = .e003,
            .summary = "--from requires --public-key",
            .hint = "Importing an entry without verifying its signature would let anyone approve configs on your behalf.",
        }, error.ConfigValidation);
    }

    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, from, ctx.arena, .unlimited) catch |err| {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{ .{ .key = "path", .value = from }, .{ .key = "detail", .value = @errorName(err) } };
        return errs.fail(.{ .code = .e012, .summary = "cannot read the shared trust entry", .context = &S.kv }, error.FileNotFound);
    };
    const entry = store_mod.parseEntry(ctx.arena, data) catch {
        const S = struct {
            var kv: [1]errs.KV = undefined;
        };
        S.kv = .{.{ .key = "path", .value = from }};
        return errs.fail(.{ .code = .e002, .summary = "shared trust entry is not valid JSON", .context = &S.kv }, error.ConfigParse);
    };

    const public = ssh_key.loadPublicKey(ctx.arena, ctx.io, public_key_path) catch |err| {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{ .{ .key = "key", .value = public_key_path }, .{ .key = "detail", .value = @errorName(err) } };
        return errs.fail(.{ .code = .e013, .summary = "cannot use public key", .context = &S.kv }, error.PermissionDenied);
    };
    sign_mod.verifyEntry(ctx.arena, entry, public) catch |err| {
        const S = struct {
            var kv: [2]errs.KV = undefined;
        };
        S.kv = .{ .{ .key = "path", .value = from }, .{ .key = "detail", .value = @errorName(err) } };
        return errs.fail(.{
            .code = .e001,
            .summary = "signature verification failed",
            .context = &S.kv,
            .hint = "The entry was modified, or it was signed by a different key.",
        }, error.TrustRequired);
    };

    try storeFor(ctx).put(ctx.arena, entry);
    try ctx.stderr.writeAll("[envee] imported verified trust entry\n");
    try ctx.stderr.print("         path:      {s}\n", .{entry.file_path});
    try ctx.stderr.print("         hash:      {s}\n", .{entry.file_hash});
    try ctx.stderr.print("         signed by: {s} (key {s})\n", .{ entry.trusted_by, entry.signature.?.key_id });
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

// ---- подписи, экспорт, импорт ----------------------------------------------

const ssh_keys_mod = @import("../trust/ssh_key.zig");

test "--sign attaches a verifiable signature and --export writes it out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const keys = (try ssh_keys_mod.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);
    const exported = try tmp.join(a, "shared.json");

    const out = try harness.runRealFull(a, tmp, &.{ "trust", "--sign", "--key", keys.private, "--export", exported }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "signed:  ed25519 (key sha256:") != null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "exported trust entry to") != null);
    // Подпись подразумевает решение: вопрос не задаётся даже без --yes.
    try testing.expect(std.mem.indexOf(u8, out.stderr, "Trust this file?") == null);

    // Файл читается обратно и проверяется публичным ключом.
    const data = try std.Io.Dir.cwd().readFileAlloc(io, exported, a, .unlimited);
    const entry = try store_mod.parseEntry(a, data);
    const public = try ssh_keys_mod.loadPublicKey(a, io, keys.public);
    try sign_mod.verifyEntry(a, entry, public);
    try testing.expectEqual(store_mod.entry_version, entry.version);

    // И одобрение при этом действует.
    _ = try harness.runReal(a, tmp, &.{ "eval", "bash" }, &.{}, null);
}

test "--from imports a verified entry and refuses a tampered one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const keys = (try ssh_keys_mod.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);

    // Рецензент подписывает и экспортирует.
    const exported = try tmp.join(a, "shared.json");
    _ = try harness.runReal(a, tmp, &.{ "trust", "--sign", "--key", keys.private, "--export", exported }, &.{}, null);

    // Коллега с чистым хранилищем импортирует по публичному ключу.
    const other = try harness.TempDir.create(a);
    defer other.destroy();
    try other.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");
    try testing.expectError(error.TrustRequired, harness.runReal(a, other, &.{ "eval", "bash" }, &.{}, null));

    const imported = try harness.runRealFull(a, other, &.{ "trust", "--from", exported, "--public-key", keys.public }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, imported.stderr, "imported verified trust entry") != null);
    try testing.expect(std.mem.indexOf(u8, imported.stderr, "signed by: tester") != null);

    // Запись привязана к пути и хешу: у коллеги тот же хеш содержимого, но
    // другой путь, поэтому его собственный eval это одобрение не покрывает.
    // Проверяем само хранилище: запись есть и сходится с подписью.
    const data = try std.Io.Dir.cwd().readFileAlloc(io, exported, a, .unlimited);
    const entry = try store_mod.parseEntry(a, data);
    const store = store_mod.Store{
        .root = (try paths_for(a, other.path)).trust_store,
        .io = io,
        .now_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
        .user = "tester",
        .tool_version = "0.4.0-test",
    };
    try testing.expectEqual(store_mod.Status.trusted, try store.status(a, entry.file_path, entry.file_hash));

    // Подделка не проходит: правим хеш в экспортированном файле.
    const forged = try tmp.join(a, "forged.json");
    const forged_text = try std.mem.replaceOwned(u8, a, data, "sha256:", "sha256:0");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = forged, .data = forged_text });
    errs.reset();
    try testing.expectError(error.TrustRequired, harness.runReal(a, other, &.{ "trust", "--from", forged, "--public-key", keys.public }, &.{}, null));
    try testing.expectEqual(errs.Code.e001, errs.take().?.code);

    // Чужой ключ тоже не проходит.
    const stranger = (try ssh_keys_mod.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer stranger.destroy(io);
    try testing.expectError(error.TrustRequired, harness.runReal(a, other, &.{ "trust", "--from", exported, "--public-key", stranger.public }, &.{}, null));
}

fn paths_for(a: Allocator, dir: []const u8) !@import("../paths.zig").Paths {
    var environ: std.process.Environ.Map = .init(a);
    try environ.put("HOME", dir);
    try environ.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ dir, "xdg-data" }));
    return @import("../paths.zig").Paths.init(a, &environ);
}

// Импорт без проверки подписи был бы способом одобрять конфиги от чужого
// имени, поэтому --from без --public-key не работает.
test "--from without --public-key is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.runReal(a, tmp, &.{ "trust", "--from", "x.json" }, &.{}, null));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e003, d.code);
    try testing.expect(std.mem.indexOf(u8, d.hint, "behalf") != null);
}

test "an unsigned export warns, and a missing or wrong key is explained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n[env]\nA = \"1\"\n");

    const exported = try tmp.join(a, "unsigned.json");
    const out = try harness.runRealFull(a, tmp, &.{ "trust", "--yes", "--export", exported }, &.{}, null);
    try testing.expect(std.mem.indexOf(u8, out.stderr, "WARN: exporting an unsigned entry") != null);

    // Ключа по пути нет.
    errs.reset();
    try testing.expectError(error.PermissionDenied, harness.runReal(a, tmp, &.{ "trust", "--yes", "--key", "/nonexistent/id_ed25519" }, &.{}, null));
    try testing.expectEqual(errs.Code.e013, errs.take().?.code);

    // RSA-ключ отвергается с подсказкой про ed25519.
    const rsa = (try ssh_keys_mod.KeyPairFiles.generate(a, io, "rsa")) orelse return error.SkipZigTest;
    defer rsa.destroy(io);
    errs.reset();
    try testing.expectError(error.PermissionDenied, harness.runReal(a, tmp, &.{ "trust", "--yes", "--key", rsa.private }, &.{}, null));
    try testing.expect(std.mem.indexOf(u8, errs.take().?.hint, "ed25519") != null);

    // --sign без --key и без ~/.ssh/id_ed25519 (HOME указывает во временный
    // каталог) — внятный отказ.
    errs.reset();
    try testing.expectError(error.ConfigValidation, harness.runReal(a, tmp, &.{ "trust", "--sign" }, &.{}, null));
    try testing.expect(std.mem.indexOf(u8, errs.take().?.hint, "ssh-keygen") != null);
}
