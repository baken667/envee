//! `envee plugin list|info` и обнаружение плагинов для `status`/`doctor`.
//!
//! Порт `internal/cli/plugin_impl.go`. Обнаружение здесь запускает каждый
//! плагин ради `metadata`: это команды осмотра, и им можно. `check` так не
//! делает — ему нельзя ничего запускать до одобрения конфига.

const std = @import("std");
const perms = @import("../perms.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const args_mod = @import("args.zig");
const context = @import("context.zig");
const errs = @import("../errs.zig");
const plugin = @import("../plugin.zig");
const Ctx = context.Ctx;

pub const Error = context.Error;

/// Бинарь плагина вместе с тем, что ответил его handshake. Метаданных нет —
/// значит, handshake не удался, и это стоит показать, а не спрятать: плагин,
/// не отвечающий на `metadata`, и секреты резолвить не будет.
pub const Discovered = struct {
    name: []const u8,
    path: []const u8,
    metadata: ?plugin.Metadata = null,
    err: []const u8 = "",
};

/// Все плагины в PATH по алфавиту; первый бинарь с данным именем выигрывает,
/// как у любой команды.
pub fn discover(ctx: *Ctx) Allocator.Error![]const Discovered {
    const path_var = ctx.environ.get("PATH") orelse "";
    var out: std.ArrayList(Discovered) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (try plugin.discoverPaths(ctx.arena, ctx.io, path_var)) |path| {
        const name = plugin.pluginName(path) orelse continue;
        if (seen.contains(name)) continue;
        try seen.put(ctx.arena, name, {});

        var d: Discovered = .{ .name = name, .path = path };
        var p: plugin.ExecPlugin = .{ .name = name, .path = path };
        if (p.fetchMetadata(ctx.arena, ctx.io, ctx.environ)) |md| {
            d.metadata = md;
        } else |_| {
            d.err = p.last_detail;
        }
        try out.append(ctx.arena, d);
    }
    std.mem.sort(Discovered, out.items, {}, byName);
    return out.toOwnedSlice(ctx.arena);
}

fn byName(_: void, a: Discovered, b: Discovered) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn runList(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const found = try discover(ctx);
    const w = ctx.stdout;

    if (parsed.boolean("json")) {
        try writeListJson(w, found, 0);
        try w.writeAll("\n");
        return;
    }
    if (found.len == 0) {
        try w.writeAll(
            \\No plugins found.
            \\
            \\envee discovers executables named envee-plugin-<name> on $PATH.
            \\The bundled local store, envee-plugin-env, ships in the same archive as envee.
            \\
        );
        return;
    }
    try w.print("{s:<14} {s:<10} {s:<5} {s}\n", .{ "NAME", "VERSION", "API", "DESCRIPTION" });
    for (found) |d| {
        if (d.metadata) |md| {
            // `{d:<5}` для знакового числа печатает `+1`; форматируем отдельно.
            const api = try std.fmt.allocPrint(ctx.arena, "{d}", .{md.api_version});
            try w.print("{s:<14} {s:<10} {s:<5} {s}\n", .{ d.name, md.version, api, md.description });
        } else {
            try w.print("{s:<14} {s:<10} {s:<5} handshake failed: {s}\n", .{ d.name, "?", "?", d.err });
        }
    }
}

pub fn runInfo(ctx: *Ctx, parsed: args_mod.Parsed) Error!void {
    const name = parsed.args[0];
    const w = ctx.stdout;
    for (try discover(ctx)) |d| {
        if (!std.mem.eql(u8, d.name, name)) continue;
        if (parsed.boolean("json")) {
            try writeDiscoveredJson(w, d, 0);
            try w.writeAll("\n");
            return;
        }
        try w.print("Plugin:      {s}\n", .{d.name});
        try w.print("Path:        {s}\n", .{d.path});
        const md = d.metadata orelse {
            try w.print("Status:      metadata handshake failed: {s}\n", .{d.err});
            return;
        };
        try w.print("Version:     {s}\n", .{md.version});
        try w.print("API version: {d}\n", .{md.api_version});
        try w.print("Description: {s}\n", .{md.description});
        if (md.capabilities) |caps| if (caps.len > 0) {
            try w.writeAll("Capabilities: ");
            try writeGoSlice(w, caps);
            try w.writeAll("\n");
        };
        try w.writeAll("Permissions:\n");
        try w.print("  network:    {}\n", .{md.permissions.network});
        if (md.permissions.filesystem) |fs| if (fs.len > 0) {
            try w.writeAll("  filesystem: ");
            try writeGoSlice(w, fs);
            try w.writeAll("\n");
        };
        if (md.permissions.exec) |ex| if (ex.len > 0) {
            try w.writeAll("  exec:       ");
            try writeGoSlice(w, ex);
            try w.writeAll("\n");
        };
        return;
    }

    const S = struct {
        var kv: [1]errs.KV = undefined;
    };
    S.kv[0] = .{ .key = "name", .value = name };
    return errs.fail(.{
        .code = .e009,
        .summary = "plugin not found",
        .context = &S.kv,
        .hint = try std.fmt.allocPrint(ctx.arena, "Run `envee plugin list` to see what is discoverable, and make sure envee-plugin-{s} is executable and on $PATH.", .{name}),
    }, error.PluginNotFound);
}

/// `%v` для среза строк в Go: `[a b]`.
fn writeGoSlice(w: *Writer, items: []const []const u8) Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(item);
    }
    try w.writeAll("]");
}

const pad = "                                        ";

/// Массив плагинов в JSON, как `json.Encoder` с отступом 2 в Go.
pub fn writeListJson(w: *Writer, found: []const Discovered, indent: usize) Writer.Error!void {
    if (found.len == 0) return w.writeAll("[]");
    try w.writeAll("[");
    for (found, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\n{s}", .{pad[0 .. indent + 2]});
        try writeDiscoveredJson(w, d, indent + 2);
    }
    try w.print("\n{s}]", .{pad[0..indent]});
}

pub fn writeDiscoveredJson(w: *Writer, d: Discovered, indent: usize) Writer.Error!void {
    const in1 = pad[0 .. indent + 2];
    try w.print("{{\n{s}\"name\": ", .{in1});
    try std.json.Stringify.value(d.name, .{}, w);
    try w.print(",\n{s}\"path\": ", .{in1});
    try std.json.Stringify.value(d.path, .{}, w);
    if (d.metadata) |md| {
        try w.print(",\n{s}\"metadata\": ", .{in1});
        try plugin.writeMetadataJson(w, md, indent + 2);
    }
    if (d.err.len > 0) {
        try w.print(",\n{s}\"error\": ", .{in1});
        try std.json.Stringify.value(d.err, .{}, w);
    }
    try w.print("\n{s}}}", .{pad[0..indent]});
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;
const harness = @import("test_harness.zig");

fn installFake(a: Allocator, tmp: harness.TempDir, names: []const []const u8) !void {
    const io = testing.io;
    const bin = try std.Io.Dir.cwd().readFileAlloc(io, @import("test_options").fake_plugin, a, .unlimited);
    for (names) |n| {
        const dst = try tmp.join(a, try plugin.exeName(a, n));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bin, .flags = .{ .permissions = perms.fromMode(0o755) } });
    }
}

test "plugin list without plugins explains where they come from" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();

    const out = try harness.run(a, tmp, &.{ "plugin", "list" }, &.{.{ "PATH", tmp.path }});
    try testing.expect(std.mem.startsWith(u8, out, "No plugins found.\n"));
    try testing.expect(std.mem.indexOf(u8, out, "envee-plugin-<name> on $PATH") != null);

    const json = try harness.run(a, tmp, &.{ "plugin", "list", "--json" }, &.{.{ "PATH", tmp.path }});
    try testing.expectEqualStrings("[]\n", json);
}

test "plugin list and info show metadata and handshake failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmp = try harness.TempDir.create(a);
    defer tmp.destroy();
    try installFake(a, tmp, &.{ "fake", "zeta" });
    const path_pair = [2][]const u8{ "PATH", tmp.path };

    const out = try harness.run(a, tmp, &.{ "plugin", "list" }, &.{path_pair});
    try testing.expectEqualStrings(
        "NAME           VERSION    API   DESCRIPTION\n" ++
            "fake           9.9.9      1     fake plugin for tests\n" ++
            "zeta           9.9.9      1     fake plugin for tests\n",
        out,
    );

    const info = try harness.run(a, tmp, &.{ "plugin", "info", "zeta" }, &.{path_pair});
    try testing.expect(std.mem.startsWith(u8, info, "Plugin:      zeta\nPath:        "));
    try testing.expect(std.mem.indexOf(u8, info, "Version:     9.9.9\nAPI version: 1\nDescription: fake plugin for tests\nCapabilities: [secret]\nPermissions:\n  network:    false\n") != null);

    // JSON — в форме Go, с метаданными как их прислал плагин.
    const json = try harness.run(a, tmp, &.{ "plugin", "info", "fake", "--json" }, &.{path_pair});
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    try testing.expectEqualStrings("fake", v.object.get("name").?.string);
    try testing.expectEqualStrings("9.9.9", v.object.get("metadata").?.object.get("version").?.string);
    try testing.expect(v.object.get("metadata").?.object.get("permissions").?.object.get("exec").? == .null);

    // Сломанный handshake виден в списке, а не спрятан.
    const broken = try harness.run(a, tmp, &.{ "plugin", "list" }, &.{ path_pair, .{ "FAKE_PLUGIN_MODE", "exit_nonzero" } });
    try testing.expect(std.mem.indexOf(u8, broken, "fake           ?          ?     handshake failed: metadata: exit status 1") != null);

    // Неизвестный плагин — E009 с подсказкой.
    errs.reset();
    try testing.expectError(error.PluginNotFound, harness.run(a, tmp, &.{ "plugin", "info", "nope" }, &.{path_pair}));
    const d = errs.take().?;
    try testing.expectEqual(errs.Code.e009, d.code);
    try testing.expect(std.mem.indexOf(u8, d.hint, "envee-plugin-nope") != null);
}
