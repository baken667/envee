//! Структурированный лог envee с автоматической редакцией секретов.
//!
//! Порт `internal/log/log.go` и `internal/log/redact.go`. В Go это обёртка
//! над `log/slog`; в Zig стандартной библиотеки такого уровня нет, поэтому
//! формат (text и json) реализован здесь.
//!
//! Главное свойство — не формат, а редакция: значение атрибута, чьё ИМЯ
//! похоже на секрет, в вывод не попадает никогда, независимо от типа
//! значения. Имя при этом остаётся видимым, иначе непонятно, о какой
//! переменной речь.
//!
//! Отличие от Go, сознательное: `AddSource` (файл и строка вызова) не
//! реализован — в Zig это потребовало бы раскрутки стека ради строки в
//! stderr короткоживущей CLI.
//!
//! Владение: `Logger` не владеет ни writer'ом, ни строками атрибутов.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Level = enum {
    trace,
    debug,
    info,
    warn,
    err,

    /// Разбор значения флага --log-level. Неизвестное значение даёт warn,
    /// как в Go-эталоне: лог не та вещь, из-за которой стоит падать.
    pub fn parse(s: []const u8) Level {
        var buf: [16]u8 = undefined;
        if (s.len == 0 or s.len > buf.len) return .warn;
        const lower = std.ascii.lowerString(&buf, s);
        if (std.mem.eql(u8, lower, "trace")) return .trace;
        if (std.mem.eql(u8, lower, "debug")) return .debug;
        if (std.mem.eql(u8, lower, "info")) return .info;
        if (std.mem.eql(u8, lower, "warn") or std.mem.eql(u8, lower, "warning")) return .warn;
        if (std.mem.eql(u8, lower, "error")) return .err;
        return .warn;
    }

    pub fn name(l: Level) []const u8 {
        return switch (l) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    fn rank(l: Level) u8 {
        return switch (l) {
            .trace => 0,
            .debug => 1,
            .info => 2,
            .warn => 3,
            .err => 4,
        };
    }
};

pub const Format = enum {
    text,
    json,

    pub fn parse(s: []const u8) Format {
        var buf: [8]u8 = undefined;
        if (s.len > 0 and s.len <= buf.len) {
            if (std.mem.eql(u8, std.ascii.lowerString(&buf, s), "json")) return .json;
        }
        return .text;
    }
};

/// Значение атрибута. Набор вариантов закрыт намеренно: редакция обязана
/// покрывать их все, а `anytype` этого не гарантирует.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
    /// Вложенная группа атрибутов.
    group: []const Attr,
};

pub const Attr = struct {
    key: []const u8,
    value: Value,
};

pub fn str(key: []const u8, v: []const u8) Attr {
    return .{ .key = key, .value = .{ .string = v } };
}

pub fn int(key: []const u8, v: i64) Attr {
    return .{ .key = key, .value = .{ .int = v } };
}

pub fn boolean(key: []const u8, v: bool) Attr {
    return .{ .key = key, .value = .{ .boolean = v } };
}

pub fn group(key: []const u8, attrs: []const Attr) Attr {
    return .{ .key = key, .value = .{ .group = attrs } };
}

// ---- редакция --------------------------------------------------------------

/// Подстрока в имени, по которой значение считается секретом.
const sensitive_substrings = [_][]const u8{
    "KEY", "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "AUTH", "PRIVATE",
};

/// Заглушка вместо секретного значения.
pub const redacted = "***REDACTED***";

/// Похоже ли имя атрибута на имя секрета.
pub fn isSensitive(key: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (key.len > buf.len) return true; // неизвестно длинное имя — перестрахуемся
    const upper = std.ascii.upperString(buf[0..key.len], key);
    for (sensitive_substrings) |sub| {
        if (std.mem.indexOf(u8, upper, sub) != null) return true;
    }
    return false;
}

// ---- логгер ----------------------------------------------------------------

pub const Options = struct {
    level: Level = .warn,
    format: Format = .text,
    /// Подавляет всё, кроме ошибок.
    quiet: bool = false,
};

pub const Logger = struct {
    /// Куда писать. null — лог выключен (например, до настройки).
    out: ?*Writer = null,
    level: Level = .warn,
    format: Format = .text,
    quiet: bool = false,

    pub fn enabled(l: Logger, level: Level) bool {
        if (l.out == null) return false;
        const min: Level = if (l.quiet) .err else l.level;
        return level.rank() >= min.rank();
    }

    /// Пишет одну запись. Ошибки записи проглатываются: сорванный лог не
    /// повод валить команду, которую пользователь просил выполнить.
    pub fn log(l: Logger, level: Level, msg: []const u8, attrs: []const Attr) void {
        if (!l.enabled(level)) return;
        const w = l.out.?;
        (switch (l.format) {
            .text => writeText(w, level, msg, attrs),
            .json => writeJson(w, level, msg, attrs),
        }) catch return;
        w.flush() catch {};
    }

    pub fn trace(l: Logger, msg: []const u8, attrs: []const Attr) void {
        l.log(.trace, msg, attrs);
    }
    pub fn debug(l: Logger, msg: []const u8, attrs: []const Attr) void {
        l.log(.debug, msg, attrs);
    }
    pub fn info(l: Logger, msg: []const u8, attrs: []const Attr) void {
        l.log(.info, msg, attrs);
    }
    pub fn warn(l: Logger, msg: []const u8, attrs: []const Attr) void {
        l.log(.warn, msg, attrs);
    }
    pub fn err(l: Logger, msg: []const u8, attrs: []const Attr) void {
        l.log(.err, msg, attrs);
    }
};

fn writeText(w: *Writer, level: Level, msg: []const u8, attrs: []const Attr) Writer.Error!void {
    try w.print("level={s} msg=", .{level.name()});
    try writeTextValue(w, .{ .string = msg });
    try writeTextAttrs(w, attrs, "");
    try w.writeByte('\n');
}

fn writeTextAttrs(w: *Writer, attrs: []const Attr, prefix: []const u8) Writer.Error!void {
    for (attrs) |a| {
        switch (a.value) {
            .group => |inner| {
                // Группа разворачивается в префикс "group.key", как это
                // делает slog в текстовом режиме.
                var buf: [128]u8 = undefined;
                const nested = std.fmt.bufPrint(&buf, "{s}{s}.", .{ prefix, a.key }) catch prefix;
                try writeTextAttrs(w, inner, nested);
            },
            else => {
                try w.print(" {s}{s}=", .{ prefix, a.key });
                if (isSensitive(a.key)) {
                    try writeTextValue(w, .{ .string = redacted });
                } else {
                    try writeTextValue(w, a.value);
                }
            },
        }
    }
}

fn writeTextValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .string => |s| {
            // Кавычки только когда без них строка распадётся на части.
            const needs_quotes = s.len == 0 or std.mem.indexOfAny(u8, s, " \t\n\"=") != null;
            if (!needs_quotes) return w.writeAll(s);
            try std.json.Stringify.value(s, .{}, w);
        },
        .int => |n| try w.print("{d}", .{n}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .group => unreachable, // группы разворачиваются выше
    }
}

fn writeJson(w: *Writer, level: Level, msg: []const u8, attrs: []const Attr) Writer.Error!void {
    try w.writeAll("{\"level\":");
    try std.json.Stringify.value(level.name(), .{}, w);
    try w.writeAll(",\"msg\":");
    try std.json.Stringify.value(msg, .{}, w);
    try writeJsonAttrs(w, attrs);
    try w.writeAll("}\n");
}

fn writeJsonAttrs(w: *Writer, attrs: []const Attr) Writer.Error!void {
    for (attrs) |a| {
        try w.writeByte(',');
        try std.json.Stringify.value(a.key, .{}, w);
        try w.writeByte(':');
        // Секретным считается имя, а не тип: значение не выходит наружу ни
        // в каком виде. В Go редакция когда-то работала только для строк, и
        // секрет, записанный числом или через Stringer, уезжал в лог целиком.
        if (isSensitive(a.key)) {
            try std.json.Stringify.value(redacted, .{}, w);
            continue;
        }
        switch (a.value) {
            .string => |s| try std.json.Stringify.value(s, .{}, w),
            .int => |n| try w.print("{d}", .{n}),
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .group => |inner| {
                try w.writeByte('{');
                var first = true;
                for (inner) |g| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(g.key, .{}, w);
                    try w.writeByte(':');
                    if (isSensitive(g.key)) {
                        try std.json.Stringify.value(redacted, .{}, w);
                    } else switch (g.value) {
                        .string => |s| try std.json.Stringify.value(s, .{}, w),
                        .int => |n| try w.print("{d}", .{n}),
                        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                        .group => try w.writeAll("{}"), // вложенность глубже двух не нужна
                    }
                }
                try w.writeByte('}');
            },
        }
    }
}

// ---- глобальный логгер -----------------------------------------------------

/// Активный логгер. Модульная переменная по той же причине, что и в errs:
/// однопоточный короткоживущий процесс, а протаскивать логгер через каждый
/// вызов — шум, ради которого пришлось бы менять сигнатуры всего дерева.
var current: Logger = .{};

/// Настраивает глобальный логгер. `out` обязан пережить процесс.
pub fn configure(out: *Writer, opts: Options) void {
    current = .{
        .out = out,
        .level = opts.level,
        .format = opts.format,
        .quiet = opts.quiet,
    };
}

pub fn setQuiet(q: bool) void {
    current.quiet = q;
}

pub fn isQuiet() bool {
    return current.quiet;
}

pub fn trace(msg: []const u8, attrs: []const Attr) void {
    current.trace(msg, attrs);
}
pub fn debug(msg: []const u8, attrs: []const Attr) void {
    current.debug(msg, attrs);
}
pub fn info(msg: []const u8, attrs: []const Attr) void {
    current.info(msg, attrs);
}
pub fn warn(msg: []const u8, attrs: []const Attr) void {
    current.warn(msg, attrs);
}
pub fn err(msg: []const u8, attrs: []const Attr) void {
    current.err(msg, attrs);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn capture(gpa: std.mem.Allocator, opts: Options, level: Level, msg: []const u8, attrs: []const Attr) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const l: Logger = .{ .out = &aw.writer, .level = opts.level, .format = opts.format, .quiet = opts.quiet };
    l.log(level, msg, attrs);
    return aw.toOwnedSlice();
}

test "isSensitive" {
    const sensitive = [_][]const u8{
        "API_KEY",               "api_key",       "DATABASE_PASSWORD", "GITHUB_TOKEN",
        "aws_secret_access_key", "MY_CREDENTIAL", "AUTH_HEADER",       "PRIVATE_KEY",
    };
    for (sensitive) |k| {
        testing.expect(isSensitive(k)) catch {
            std.debug.print("isSensitive({s}) = false, want true\n", .{k});
            return error.TestExpectedEqual;
        };
    }
    const benign = [_][]const u8{ "SERVICE_NAME", "PORT", "LOG_LEVEL", "DATABASE_URL", "path" };
    for (benign) |k| {
        testing.expect(!isSensitive(k)) catch {
            std.debug.print("isSensitive({s}) = true, want false\n", .{k});
            return error.TestExpectedEqual;
        };
    }
}

test "a sensitive value never reaches the output, in either format" {
    for ([_]Format{ .text, .json }) |format| {
        const out = try capture(testing.allocator, .{ .level = .debug, .format = format }, .info, "resolved", &.{
            str("API_KEY", "sk_live_supersecret"),
            str("SERVICE_NAME", "myapp"),
        });
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "sk_live_supersecret") == null);
        try testing.expect(std.mem.indexOf(u8, out, redacted) != null);
        // Имя переменной остаётся видимым, иначе непонятно, о чём строка;
        // безобидное значение не должно пострадать.
        try testing.expect(std.mem.indexOf(u8, out, "API_KEY") != null);
        try testing.expect(std.mem.indexOf(u8, out, "myapp") != null);
    }
}

// Редакция когда-то распространялась только на строки, и секрет, записанный
// числом или булевым значением, уходил в лог целиком.
test "redaction ignores the value's type" {
    for ([_]Format{ .text, .json }) |format| {
        const out = try capture(testing.allocator, .{ .level = .debug, .format = format }, .info, "m", &.{
            int("SECRET_VALUE", 1234567890),
            boolean("TOKEN_PRESENT", true),
        });
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "1234567890") == null);
        try testing.expect(std.mem.indexOf(u8, out, "true") == null);
        try testing.expect(std.mem.indexOf(u8, out, redacted) != null);
    }
}

test "redaction reaches inside groups" {
    for ([_]Format{ .text, .json }) |format| {
        const out = try capture(testing.allocator, .{ .level = .debug, .format = format }, .info, "m", &.{
            group("env", &.{
                str("DB_PASSWORD", "hunter2"),
                str("SERVICE_NAME", "myapp"),
            }),
        });
        defer testing.allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "hunter2") == null);
        try testing.expect(std.mem.indexOf(u8, out, redacted) != null);
        // Безобидное значение внутри группы обязано уцелеть.
        try testing.expect(std.mem.indexOf(u8, out, "myapp") != null);
    }
}

test "levels filter, and quiet leaves only errors" {
    // Ниже порога — ничего не пишется.
    const below = try capture(testing.allocator, .{ .level = .warn }, .info, "m", &.{});
    defer testing.allocator.free(below);
    try testing.expectEqualStrings("", below);

    const at = try capture(testing.allocator, .{ .level = .warn }, .warn, "m", &.{});
    defer testing.allocator.free(at);
    try testing.expect(at.len > 0);

    const quiet_warn = try capture(testing.allocator, .{ .level = .trace, .quiet = true }, .warn, "m", &.{});
    defer testing.allocator.free(quiet_warn);
    try testing.expectEqualStrings("", quiet_warn);

    const quiet_err = try capture(testing.allocator, .{ .level = .trace, .quiet = true }, .err, "m", &.{});
    defer testing.allocator.free(quiet_err);
    try testing.expect(quiet_err.len > 0);
}

test "text format" {
    const out = try capture(testing.allocator, .{ .level = .debug }, .info, "hello world", &.{
        str("path", "/a/b"),
        str("spaced", "two words"),
        int("count", 42),
        boolean("ok", true),
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "level=INFO msg=\"hello world\" path=/a/b spaced=\"two words\" count=42 ok=true\n",
        out,
    );
}

test "json format" {
    const out = try capture(testing.allocator, .{ .level = .debug, .format = .json }, .warn, "hi", &.{
        str("path", "/a/b"),
        int("count", 42),
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"level\":\"WARN\",\"msg\":\"hi\",\"path\":\"/a/b\",\"count\":42}\n",
        out,
    );
}

test "json output stays parseable with awkward values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try capture(a, .{ .level = .debug, .format = .json }, .info, "m", &.{
        str("quotes", "he said \"hi\""),
        str("newline", "a\nb"),
        str("utf8", "Привет 🎉"),
        group("nested", &.{str("inner", "value")}),
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("he said \"hi\"", parsed.value.object.get("quotes").?.string);
    try testing.expectEqualStrings("a\nb", parsed.value.object.get("newline").?.string);
    try testing.expectEqualStrings("value", parsed.value.object.get("nested").?.object.get("inner").?.string);
}

test "level and format parsing tolerate junk" {
    try testing.expectEqual(Level.trace, Level.parse("trace"));
    try testing.expectEqual(Level.debug, Level.parse("DEBUG"));
    try testing.expectEqual(Level.warn, Level.parse("warning"));
    try testing.expectEqual(Level.err, Level.parse("error"));
    // Неизвестный уровень не повод падать: лог — не то, ради чего стоит
    // прерывать команду.
    try testing.expectEqual(Level.warn, Level.parse("nonsense"));
    try testing.expectEqual(Level.warn, Level.parse(""));

    try testing.expectEqual(Format.json, Format.parse("JSON"));
    try testing.expectEqual(Format.text, Format.parse("text"));
    try testing.expectEqual(Format.text, Format.parse("nonsense"));
}

test "an unconfigured logger writes nowhere and does not crash" {
    const l: Logger = .{};
    l.info("dropped", &.{str("K", "v")});
    try testing.expect(!l.enabled(.err));
}
