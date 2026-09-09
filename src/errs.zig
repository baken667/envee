//! Ошибки envee: стабильный код, человеческое объяснение, подсказка.
//!
//! Порт `internal/errs/errs.go`. См. docs/adr/0017-error-ux.md и
//! docs/errors.md, где каждый код расписан.
//!
//! В Go ошибка — это структура, реализующая интерфейс `error`, и она несёт с
//! собой все подробности. В Zig ошибка — значение перечисления без нагрузки,
//! поэтому подробности едут рядом, в `Diag`.
//!
//! Передаются они через `fail`, который запоминает диагностику в модуле и
//! возвращает ошибку; верхний уровень CLI забирает её через `take`. Это
//! допустимо ровно потому, что envee — короткоживущий однопоточный процесс,
//! обрабатывающий одну команду. `take` очищает сохранённое, чтобы устаревшая
//! диагностика не всплыла второй раз рядом с чужой ошибкой.
//!
//! Владение: `Diag` не владеет своими строками. Всё, что в него кладут,
//! обязано пережить печать — в проде это арена процесса.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Severity = enum {
    err,
    warn,
    info,

    pub fn name(s: Severity) []const u8 {
        return switch (s) {
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
        };
    }
};

/// Стабильные коды ошибок. Не переиспользовать и не переназначать: на них
/// ссылаются docs/errors.md и скрипты пользователей.
pub const Code = enum {
    e001,
    e002,
    e003,
    e004,
    e005,
    e006,
    e007,
    e008,
    e009,
    e010,
    e011,
    e012,
    e013,
    e014,
    e015,

    /// Код в том виде, в каком он печатается: "E001".
    pub fn name(c: Code) []const u8 {
        return switch (c) {
            .e001 => "E001",
            .e002 => "E002",
            .e003 => "E003",
            .e004 => "E004",
            .e005 => "E005",
            .e006 => "E006",
            .e007 => "E007",
            .e008 => "E008",
            .e009 => "E009",
            .e010 => "E010",
            .e011 => "E011",
            .e012 => "E012",
            .e013 => "E013",
            .e014 => "E014",
            .e015 => "E015",
        };
    }

    /// Код процесса. Разбит по смыслу, чтобы скрипты могли отличить «нужно
    /// одобрить конфиг» от «конфиг сломан» без разбора текста.
    ///
    ///   3 — доверие, 4 — конфигурация, 5 — плагин, сеть или демон, 1 — прочее.
    pub fn exitCode(c: Code) u8 {
        return switch (c) {
            .e001, .e010 => 3,
            .e002, .e003, .e007, .e008, .e012 => 4,
            .e004, .e009, .e011, .e015 => 5,
            else => 1,
        };
    }

    /// Ссылка на раздел документации.
    pub fn writeDocUrl(c: Code, w: *Writer) Writer.Error!void {
        // Домен envee.dev так и не был зарегистрирован; ссылаемся на
        // документацию, которая действительно существует.
        try w.writeAll("https://github.com/baken667/envee/blob/main/docs/errors.md#");
        var buf: [4]u8 = undefined;
        try w.writeAll(std.ascii.lowerString(&buf, c.name()));
    }
};

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Максимум пар в контексте. Самая многословная ошибка (E002) кладёт четыре.
pub const max_context = 8;

/// Подробности ошибки: то, что в Go было полями структуры `errs.Error`.
pub const Diag = struct {
    code: Code,
    severity: Severity = .err,
    /// Одна строка о том, что произошло.
    summary: []const u8,
    /// Структурированные детали. Печатаются с отсортированными ключами.
    context: []const KV = &.{},
    /// Что пользователь может сделать.
    hint: []const u8 = "",
    /// Нижележащая ошибка, если она была.
    cause: ?anyerror = null,

    /// Печатает ошибку в том же виде, что и Go-эталон.
    pub fn write(d: Diag, w: *Writer) Writer.Error!void {
        try w.print("[envee] {s} [{s}]: {s}", .{ d.severity.name(), d.code.name(), d.summary });

        if (d.context.len > 0) {
            var buf: [max_context]KV = undefined;
            const n = @min(d.context.len, buf.len);
            @memcpy(buf[0..n], d.context[0..n]);
            const sorted = buf[0..n];
            std.mem.sort(KV, sorted, {}, lessThanKey);

            try w.writeAll("\n[envee]   context:");
            for (sorted) |kv| {
                try w.print("\n[envee]     {s}: {s}", .{ kv.key, kv.value });
            }
        }
        if (d.hint.len > 0) try w.print("\n[envee] HINT: {s}", .{d.hint});
        try w.writeAll("\n[envee] DOC:  ");
        try d.code.writeDocUrl(w);
        if (d.cause) |c| try w.print("\n[envee] CAUSE: {s}", .{@errorName(c)});
    }

    pub fn exitCode(d: Diag) u8 {
        return d.code.exitCode();
    }
};

fn lessThanKey(_: void, a: KV, b: KV) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Набор ошибок envee. Каждая соответствует одному или нескольким кодам;
/// точный код и подробности лежат в `Diag`.
pub const Error = error{
    /// E001 — конфиг не одобрен.
    TrustRequired,
    /// E010 — конфиг явно запрещён.
    TrustDenied,
    /// E002 — TOML не разбирается.
    ConfigParse,
    /// E003 — значение в конфиге недопустимо.
    ConfigValidation,
    /// E004 — плагин секретов ответил ошибкой.
    PluginFailed,
    /// E005 — шаблон не вычисляется.
    TemplateFailed,
    /// E006 — WASM-скрипт не выполнился.
    ScriptFailed,
    /// E007 — циклическая зависимость.
    CycleDetected,
    /// E008 — обязательная переменная не задана.
    RequiredVarMissing,
    /// E009 — плагин не найден.
    PluginNotFound,
    /// E011 — демон недоступен.
    DaemonFailed,
    /// E012 — файл не найден.
    FileNotFound,
    /// E013 — нет прав.
    PermissionDenied,
    /// E014 — несовместимая версия.
    VersionIncompatible,
    /// E015 — сетевая ошибка.
    NetworkFailed,
};

// ---- передача диагностики --------------------------------------------------

/// Последняя диагностика. Модульная переменная, а не параметр, потому что
/// ошибка всплывает через десяток слоёв, и протаскивать указатель через
/// каждый — шум. Безопасно ровно в силу того, что процесс однопоточный и
/// живёт одну команду.
var last: ?Diag = null;

/// Запоминает подробности и возвращает ошибку, чтобы её можно было вернуть
/// одним выражением: `return errs.fail(.{ ... }, error.TrustRequired);`
pub fn fail(d: Diag, e: Error) Error {
    last = d;
    return e;
}

/// Забирает и очищает сохранённую диагностику.
///
/// Очистка обязательна: без неё диагностика от давно обработанной ошибки
/// всплыла бы рядом с совершенно другой, и пользователь получил бы неверное
/// объяснение.
pub fn take() ?Diag {
    defer last = null;
    return last;
}

/// Сбрасывает сохранённую диагностику, не читая её.
pub fn reset() void {
    last = null;
}

// ---- конструкторы частых ошибок --------------------------------------------
//
// Каждый повторяет соответствующий helper из Go-эталона, вплоть до текста:
// эти строки видит пользователь, и расхождение здесь — расхождение в UX.
//
// Контекст и summary ссылаются на память вызывающего: буфер под пары он
// передаёт сам, а строки, которые надо собрать, выделяются из `gpa`. В проде
// это арена процесса, поэтому освобождать их не нужно.

pub const FailError = Error || Allocator.Error;

/// E001 — конфиг не одобрен пользователем.
pub fn trustRequired(
    gpa: Allocator,
    path: []const u8,
    hash: []const u8,
    context: *[2]KV,
) FailError {
    // Называем конкретный файл. Разрешённый конфиг склеивается из нескольких
    // (envee.local.toml, envee.d/*.toml, конфиги родительских каталогов), и
    // жёстко вписанное «envee.toml» отправляло пользователя не туда.
    const summary = try std.fmt.allocPrint(gpa, "{s} is not trusted", .{std.fs.path.basename(path)});
    context.* = .{
        .{ .key = "path", .value = path },
        .{ .key = "hash", .value = hash },
    };
    return fail(.{
        .code = .e001,
        .summary = summary,
        .context = context,
        .hint = "Run `envee trust` to review and approve its content.",
    }, error.TrustRequired);
}

/// E002 — TOML не разобрался.
pub fn configParse(
    gpa: Allocator,
    path: []const u8,
    line: usize,
    column: usize,
    detail: []const u8,
    context: *[4]KV,
) FailError {
    context.* = .{
        .{ .key = "path", .value = path },
        .{ .key = "line", .value = try std.fmt.allocPrint(gpa, "{d}", .{line}) },
        .{ .key = "column", .value = try std.fmt.allocPrint(gpa, "{d}", .{column}) },
        .{ .key = "detail", .value = detail },
    };
    return fail(.{
        .code = .e002,
        .summary = "failed to parse envee.toml",
        .context = context,
        .hint = "Check TOML syntax at the indicated line.",
    }, error.ConfigParse);
}

/// E003 — значение в конфиге недопустимо.
pub fn configValidation(path: []const u8, key: []const u8, detail: []const u8, context: *[3]KV) Error {
    context.* = .{
        .{ .key = "path", .value = path },
        .{ .key = "key", .value = key },
        .{ .key = "detail", .value = detail },
    };
    return fail(.{
        .code = .e003,
        .summary = "invalid value in envee.toml",
        .context = context,
    }, error.ConfigValidation);
}

/// E008 — обязательная переменная не определена.
pub fn requiredVarMissing(name: []const u8, profile: []const u8, context: *[2]KV) Error {
    var n: usize = 1;
    context[0] = .{ .key = "variable", .value = name };
    if (profile.len > 0) {
        context[1] = .{ .key = "profile", .value = profile };
        n = 2;
    }
    return fail(.{
        .code = .e008,
        .summary = "required variable not defined",
        .context = context[0..n],
        .hint = "Set it in envee.toml, .env file, or via a secret plugin.",
    }, error.RequiredVarMissing);
}

/// E009 — плагин секретов не найден в PATH.
pub fn pluginNotFound(gpa: Allocator, source: []const u8, context: *[2]KV) FailError {
    context.* = .{
        .{ .key = "source", .value = source },
        .{ .key = "plugin", .value = try std.fmt.allocPrint(gpa, "envee-plugin-{s}", .{source}) },
    };
    return fail(.{
        .code = .e009,
        .summary = "secret plugin not found",
        .context = context,
        .hint = try std.fmt.allocPrint(gpa, "Install with: brew install baken/tap/envee-plugin-{s}", .{source}),
    }, error.PluginNotFound);
}

/// E007 — цикл в шаблонах. `chain` — уже собранная цепочка "A -> B -> A".
pub fn cycleDetected(chain: []const u8, context: *[1]KV) Error {
    context.* = .{.{ .key = "chain", .value = chain }};
    return fail(.{
        .code = .e007,
        .summary = "circular dependency in template",
        .context = context,
        .hint = "Break the cycle by using a constant value.",
    }, error.CycleDetected);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn renderDiag(gpa: Allocator, d: Diag) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try d.write(&aw.writer);
    return aw.toOwnedSlice();
}

test "codes map to the documented exit codes" {
    // Разбиение по смыслу: 3 — доверие, 4 — конфигурация, 5 — внешние
    // системы. На эти числа опираются скрипты пользователей.
    try testing.expectEqual(@as(u8, 3), Code.e001.exitCode());
    try testing.expectEqual(@as(u8, 3), Code.e010.exitCode());
    for ([_]Code{ .e002, .e003, .e007, .e008, .e012 }) |c| {
        try testing.expectEqual(@as(u8, 4), c.exitCode());
    }
    for ([_]Code{ .e004, .e009, .e011, .e015 }) |c| {
        try testing.expectEqual(@as(u8, 5), c.exitCode());
    }
    for ([_]Code{ .e005, .e006, .e013, .e014 }) |c| {
        try testing.expectEqual(@as(u8, 1), c.exitCode());
    }
}

test "every code has a distinct name and a doc anchor" {
    var seen: [15][]const u8 = undefined;
    var n: usize = 0;
    for (std.enums.values(Code)) |c| {
        for (seen[0..n]) |s| try testing.expect(!std.mem.eql(u8, s, c.name()));
        seen[n] = c.name();
        n += 1;

        var aw: Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try c.writeDocUrl(&aw.writer);
        // Якорь — код в нижнем регистре.
        try testing.expect(std.mem.endsWith(u8, aw.written(), "#e0"[0..2]) == false);
        try testing.expect(std.mem.indexOf(u8, aw.written(), "docs/errors.md#") != null);
    }
    try testing.expectEqual(@as(usize, 15), n);
}

test "rendering matches the Go layout" {
    const d: Diag = .{
        .code = .e001,
        .summary = "envee.toml is not trusted",
        .context = &.{
            .{ .key = "path", .value = "/home/alice/proj/envee.toml" },
            .{ .key = "hash", .value = "sha256:abc" },
        },
        .hint = "Run `envee trust` to review and approve its content.",
    };
    const got = try renderDiag(testing.allocator, d);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(
        "[envee] ERROR [E001]: envee.toml is not trusted\n" ++
            "[envee]   context:\n" ++
            // Ключи отсортированы: hash идёт раньше path.
            "[envee]     hash: sha256:abc\n" ++
            "[envee]     path: /home/alice/proj/envee.toml\n" ++
            "[envee] HINT: Run `envee trust` to review and approve its content.\n" ++
            "[envee] DOC:  https://github.com/baken667/envee/blob/main/docs/errors.md#e001",
        got,
    );
}

test "rendering without context, hint or cause" {
    const got = try renderDiag(testing.allocator, .{ .code = .e012, .summary = "no envee.toml found" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "[envee] ERROR [E012]: no envee.toml found\n" ++
            "[envee] DOC:  https://github.com/baken667/envee/blob/main/docs/errors.md#e012",
        got,
    );
}

test "severity and cause are rendered" {
    const got = try renderDiag(testing.allocator, .{
        .code = .e009,
        .severity = .warn,
        .summary = "secret plugin not found",
        .cause = error.FileNotFound,
    });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "[envee] WARN [E009]: "));
    try testing.expect(std.mem.endsWith(u8, got, "\n[envee] CAUSE: FileNotFound"));
}

test "fail stores the diagnostic and take clears it" {
    reset();
    try testing.expect(take() == null);

    const e = fail(.{ .code = .e003, .summary = "bad value" }, error.ConfigValidation);
    try testing.expectEqual(Error.ConfigValidation, e);

    const d = take().?;
    try testing.expectEqual(Code.e003, d.code);
    try testing.expectEqualStrings("bad value", d.summary);

    // Устаревшая диагностика не должна всплыть рядом с другой ошибкой.
    try testing.expect(take() == null);
}

test "trustRequired names the actual file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    reset();
    var ctx: [2]KV = undefined;
    // Конструкторы возвращают ЗНАЧЕНИЕ ошибки, а не error union: они всегда
    // завершаются ошибкой, в этом их смысл.
    const e = trustRequired(a, "/home/alice/proj/envee.local.toml", "sha256:abc", &ctx);
    try testing.expectEqual(FailError.TrustRequired, e);

    const d = take().?;
    try testing.expectEqual(Code.e001, d.code);
    // Не «envee.toml», а тот файл, который на самом деле не одобрен.
    try testing.expectEqualStrings("envee.local.toml is not trusted", d.summary);
    try testing.expectEqual(@as(usize, 2), d.context.len);
    try testing.expectEqual(@as(u8, 3), d.exitCode());
}

test "requiredVarMissing omits an empty profile" {
    reset();
    var ctx: [2]KV = undefined;
    _ = requiredVarMissing("DATABASE_URL", "", &ctx) catch {};
    try testing.expectEqual(@as(usize, 1), take().?.context.len);

    _ = requiredVarMissing("DATABASE_URL", "prod", &ctx) catch {};
    const d = take().?;
    try testing.expectEqual(@as(usize, 2), d.context.len);
    try testing.expectEqualStrings("prod", d.context[1].value);
}

test "cycleDetected carries the chain" {
    reset();
    var ctx: [1]KV = undefined;
    _ = cycleDetected("A -> B -> A", &ctx) catch {};
    const d = take().?;
    try testing.expectEqual(Code.e007, d.code);
    try testing.expectEqualStrings("A -> B -> A", d.context[0].value);
    try testing.expectEqual(@as(u8, 4), d.exitCode());
}
