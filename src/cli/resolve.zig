//! Команды `envee resolve` и `envee diff`.
//!
//! Порт `internal/cli/resolve.go` и `internal/cli/diff.go`.
//!
//! Обе показывают, что получится, но не применяют результат. Значения,
//! помеченные `redact`, ни в одной из них не печатаются: вывод этих команд
//! регулярно оказывается в чужих логах и в отчётах об ошибках.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const directive = @import("../directive.zig");
const shell = @import("../shell/shell.zig");

const Ctx = context.Ctx;
const Error = context.Error;

/// Заглушка вместо значения, помеченного redact.
pub const redacted_placeholder = "***REDACTED***";

pub fn runResolve(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const r = try context.resolveEnv(ctx, parsed.str("profile"), stop_at);
    if (parsed.boolean("json")) return writeJson(ctx, r.result);
    return writeText(ctx, r.result);
}

fn writeText(ctx: *Ctx, result: directive.Result) Error!void {
    for (result.env.entries.items) |e| {
        if (e.redacted) {
            try ctx.stdout.print("{s}={s}\n", .{ e.key, redacted_placeholder });
        } else {
            try ctx.stdout.print("{s}={s}\n", .{ e.key, e.value });
        }
    }
}

/// JSON: `{"KEY": {"source": ..., "value": ...}}`, отступ в два пробела.
///
/// Ключи объекта идут отсортированными на обоих уровнях: `env.Map` хранит
/// переменные по порядку, а поля записи печатаются в том же порядке, что
/// даёт кодировщик Go по алфавиту — `redacted`, `source`, `value`.
fn writeJson(ctx: *Ctx, result: directive.Result) Error!void {
    const w = ctx.stdout;
    // Пустой объект кодировщик Go печатает как "{}", без переноса внутри.
    if (result.env.entries.items.len == 0) return w.writeAll("{}\n");

    try w.writeAll("{\n");
    for (result.env.entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("  ");
        try std.json.Stringify.value(e.key, .{}, w);
        try w.writeAll(": {\n");
        if (e.redacted) {
            try w.writeAll("    \"redacted\": true,\n");
        }
        try w.writeAll("    \"source\": ");
        try std.json.Stringify.value(e.source, .{}, w);
        try w.writeAll(",\n    \"value\": ");
        try std.json.Stringify.value(if (e.redacted) redacted_placeholder else e.value, .{}, w);
        try w.writeAll("\n  }");
    }
    try w.writeAll("\n}\n");
}

/// `envee diff <shell>` — тот же вывод, что у `eval`, но без списка
/// зависимостей: его читает hook, а не человек.
pub fn runDiff(ctx: *Ctx, parsed: args_mod.Parsed, stop_at: []const u8) Error!void {
    const adapter = shell.Adapter.detect(parsed.args[0]) orelse
        return context.unsupportedShell(parsed.args[0]);

    const r = try context.resolveEnv(ctx, parsed.str("profile"), stop_at);

    if (!parsed.boolean("json")) {
        return context.writeShellDiff(ctx, ctx.stdout, adapter, r.result);
    }

    var body: Writer.Allocating = .init(ctx.arena);
    try context.writeShellDiff(ctx, &body.writer, adapter, r.result);

    // Однострочный JSON без отступов, поля по алфавиту.
    const w = ctx.stdout;
    try w.writeAll("{\"output\":");
    try std.json.Stringify.value(body.written(), .{}, w);
    try w.writeAll(",\"profile\":");
    try std.json.Stringify.value(r.loaded.profile, .{}, w);
    try w.writeAll(",\"shell\":");
    try std.json.Stringify.value(adapter.name(), .{}, w);
    try w.writeAll("}\n");
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

test "resolve prints sorted KEY=VALUE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\[env]
        \\ZEBRA = "last"
        \\ALPHA = "first"
        \\PORT = 5432
    );

    const out = try harness.run(a, tmp, &.{"resolve"}, &.{});
    try testing.expectEqualStrings("ALPHA=first\nPORT=5432\nZEBRA=last\n", out);
}

// Вывод resolve регулярно попадает в чужие логи, поэтому секрет там не
// печатается ни при каких обстоятельствах.
test "resolve masks redacted values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\[env]
        \\PLAIN = "visible"
        \\API_KEY = { value = "sk_live_supersecret", redact = true }
    );

    const out = try harness.run(a, tmp, &.{"resolve"}, &.{});
    try testing.expect(std.mem.indexOf(u8, out, "sk_live_supersecret") == null);
    try testing.expect(std.mem.indexOf(u8, out, "API_KEY=***REDACTED***") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PLAIN=visible") != null);
}

test "resolve --json carries the source of each value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a,
        \\[env]
        \\A = "1"
        \\SECRET = { value = "s", redact = true }
    );

    const out = try harness.run(a, tmp, &.{ "resolve", "--json" }, &.{});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();

    const av = parsed.value.object.get("A").?.object;
    try testing.expectEqualStrings("1", av.get("value").?.string);
    try testing.expectEqualStrings("toml", av.get("source").?.string);
    try testing.expect(av.get("redacted") == null);

    const sv = parsed.value.object.get("SECRET").?.object;
    try testing.expectEqualStrings(redacted_placeholder, sv.get("value").?.string);
    try testing.expectEqual(true, sv.get("redacted").?.bool);
    try testing.expect(std.mem.indexOf(u8, out, "\"s\"") == null);
}

test "resolve --json on an empty config is still valid JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "schema = \"envee/v1\"\n");

    const out = try harness.run(a, tmp, &.{ "resolve", "--json" }, &.{});
    try testing.expectEqualStrings("{}\n", out);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
}

test "diff prints what eval would, without the dependency list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n");

    const out = try harness.run(a, tmp, &.{ "diff", "bash" }, &.{.{ "PATH", "/usr/bin" }});
    try testing.expectEqualStrings("export A=1;\n", out);
    // Список зависимостей читает hook, а не человек.
    try testing.expect(std.mem.indexOf(u8, out, "__envee_deps") == null);
}

test "diff --json wraps the output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n[profiles.dev.env]\nB = \"2\"\n");

    const out = try harness.run(a, tmp, &.{ "--profile", "dev", "diff", "fish", "--json" }, &.{.{ "PATH", "/usr/bin" }});
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("fish", parsed.value.object.get("shell").?.string);
    try testing.expectEqualStrings("dev", parsed.value.object.get("profile").?.string);
    const body = parsed.value.object.get("output").?.string;
    try testing.expect(std.mem.indexOf(u8, body, "set -gx A '1'") != null);
    try testing.expect(std.mem.indexOf(u8, body, "set -gx B '2'") != null);
}

test "diff refuses an unsupported shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n");

    try testing.expectError(error.ConfigValidation, harness.run(a, tmp, &.{ "diff", "tcsh" }, &.{}));
}

// Директивы умеют вызывать плагины и читать файлы, поэтому неодобренный
// конфиг не должен доходить до них ни в resolve, ни в diff.
test "resolve and diff refuse an untrusted config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try tmp.write(a, "[env]\nA = \"1\"\n");

    try testing.expectError(error.TrustRequired, harness.runUntrusted(a, tmp, &.{"resolve"}, &.{}));
    try testing.expectError(error.TrustRequired, harness.runUntrusted(a, tmp, &.{ "diff", "bash" }, &.{}));
}
