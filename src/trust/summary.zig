//! Сводка того, что даёт одобрение конфига.
//!
//! Порт `internal/trust/summary.go`.
//!
//! Это единственный текст, по которому пользователь решает, впускать ли
//! чужой конфиг в свою оболочку. Поэтому здесь перечисляется всё, что
//! конфиг МОЖЕТ сделать, а не только то, что бросается в глаза: добавления
//! в $PATH, подключаемые файлы, вызовы плагинов секретов и скрипты.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const config = @import("../config.zig");

pub const Summary = struct {
    path: []const u8 = "",
    hash: []const u8 = "",
    schema: []const u8 = "",
    profile: []const u8 = "",

    env_vars: []const []const u8 = &.{},
    redacted_vars: []const []const u8 = &.{},
    path_adds: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    secrets: []const []const u8 = &.{},
    scripts: usize = 0,

    warnings: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
};

/// Похоже ли имя переменной на имя секрета.
///
/// Совпадает с `nameLooksSensitive` в Go: простое вхождение подстроки, без
/// границ слова. Поэтому `AUTHOR` тоже считается чувствительным — здесь это
/// осознанный перекос в сторону лишнего предупреждения, а не пропуска.
pub fn nameLooksSensitive(name: []const u8) bool {
    const parts = [_][]const u8{ "KEY", "SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "AUTH", "PRIVATE" };
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return true;
    const upper = std.ascii.upperString(buf[0..name.len], name);
    for (parts) |p| {
        if (std.mem.indexOf(u8, upper, p) != null) return true;
    }
    return false;
}

pub fn build(arena: Allocator, cfg: config.Config) Allocator.Error!Summary {
    var s: Summary = .{
        .path = cfg.path,
        .hash = cfg.file_hash,
        .schema = cfg.schema,
        .profile = cfg.profile,
        .scripts = cfg.directives.script.len,
    };

    var path_adds: std.ArrayList([]const u8) = .empty;
    for (cfg.directives.path) |p| try path_adds.append(arena, p.path);
    s.path_adds = try path_adds.toOwnedSlice(arena);

    var files: std.ArrayList([]const u8) = .empty;
    for (cfg.directives.file) |f| {
        const text = if (f.format.len > 0)
            try std.fmt.allocPrint(arena, "{s} ({s})", .{ f.path, f.format })
        else
            f.path;
        try files.append(arena, text);
    }
    s.files = try files.toOwnedSlice(arena);

    // Через secretRefs, чтобы в сводку попали и секреты, записанные
    // сокращённо. Без этого пользователю просто не сообщали, что одобрение
    // этого конфига разрешает вызов плагина секретов.
    var secrets: std.ArrayList([]const u8) = .empty;
    for (try cfg.secretRefs(arena)) |sec| {
        try secrets.append(arena, try std.fmt.allocPrint(
            arena,
            "{s} = {s}://{s}",
            .{ sec.name, sec.ref.source, sec.ref.ref },
        ));
    }
    const secret_list = try secrets.toOwnedSlice(arena);
    std.mem.sort([]const u8, @constCast(secret_list), {}, lessThanSlice);
    s.secrets = secret_list;

    var env_vars: std.ArrayList([]const u8) = .empty;
    var redacted: std.ArrayList([]const u8) = .empty;
    for (cfg.env.keys(), cfg.env.map.values()) |k, v| {
        if (std.mem.eql(u8, k, "_") or config.isMetaKey(k)) continue;

        if (v.asTable()) |t| {
            if (t.get("redact")) |r| {
                if (r.asBool() orelse false) {
                    try redacted.append(arena, k);
                    continue;
                }
            }
        }
        if (nameLooksSensitive(k)) try redacted.append(arena, k);
        try env_vars.append(arena, k);
    }
    s.env_vars = try env_vars.toOwnedSlice(arena);
    s.redacted_vars = try redacted.toOwnedSlice(arena);

    var warnings: std.ArrayList([]const u8) = .empty;
    if (s.scripts > 0) {
        try warnings.append(arena, try std.fmt.allocPrint(
            arena,
            "{d} script(s) referenced — review WASM modules",
            .{s.scripts},
        ));
    }
    for (s.env_vars) |name| {
        if (!nameLooksSensitive(name)) continue;
        try warnings.append(arena, try std.fmt.allocPrint(
            arena,
            "{s} looks like a secret but redact=false",
            .{name},
        ));
    }
    s.warnings = try warnings.toOwnedSlice(arena);

    var errors: std.ArrayList([]const u8) = .empty;
    for (s.secrets) |sec| {
        if (std.mem.indexOf(u8, sec, "unknown://") == null) continue;
        try errors.append(arena, try std.fmt.allocPrint(arena, "secret source unknown: {s}", .{sec}));
    }
    s.errors = try errors.toOwnedSlice(arena);

    return s;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn write(w: *Writer, s: Summary) Writer.Error!void {
    try w.print("Trust {s}\n", .{s.path});
    try w.print("  Schema:     {s}\n", .{s.schema});
    if (s.profile.len > 0) try w.print("  Profile:    {s}\n", .{s.profile});
    try w.print("  Hash:       {s}\n\n", .{s.hash});

    try w.print("  Env vars:   {d}", .{s.env_vars.len});
    if (s.redacted_vars.len > 0) try w.print(" ({d} marked redact)", .{s.redacted_vars.len});
    try w.writeByte('\n');

    if (s.path_adds.len > 0) {
        try w.print("  PATH adds:  {d}\n", .{s.path_adds.len});
        for (s.path_adds) |p| try w.print("              - {s}\n", .{p});
    }
    if (s.files.len > 0) {
        try w.print("  Files:      {d}\n", .{s.files.len});
        for (s.files) |f| try w.print("              - {s}\n", .{f});
    }
    if (s.scripts > 0) {
        try w.print("  Scripts:    {d} (review WASM modules)\n", .{s.scripts});
    }
    if (s.secrets.len > 0) {
        try w.print("  Secrets:    {d}\n", .{s.secrets.len});
        for (s.secrets) |sec| try w.print("              - {s}\n", .{sec});
    }

    try w.writeByte('\n');
    if (s.warnings.len > 0) {
        try w.writeAll("Security warnings:\n");
        for (s.warnings) |x| try w.print("  ⚠ {s}\n", .{x});
        try w.writeByte('\n');
    }
    if (s.errors.len > 0) {
        try w.writeAll("Security errors (will block trust unless --force):\n");
        for (s.errors) |x| try w.print("  ✗ {s}\n", .{x});
        try w.writeByte('\n');
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn summaryOf(arena: Allocator, src: []const u8) !Summary {
    const cfg = try config.parseBytes(arena, "/p/envee.toml", src, null);
    return build(arena, cfg);
}

test "the summary counts what approving the config allows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a,
        \\schema = "envee/v1"
        \\profile = "dev"
        \\
        \\[env]
        \\SERVICE_NAME = "myapp"
        \\PORT = 5432
        \\API_KEY = { value = "x", redact = true }
        \\_.path = ["./bin", "./tools"]
        \\_.file = [{ path = ".env" }, { path = "extra.json", format = "json" }]
    );

    try testing.expectEqualStrings("envee/v1", s.schema);
    try testing.expectEqualStrings("dev", s.profile);
    try testing.expect(std.mem.startsWith(u8, s.hash, "sha256:"));
    try testing.expectEqual(@as(usize, 2), s.env_vars.len);
    try testing.expectEqual(@as(usize, 1), s.redacted_vars.len);
    try testing.expectEqual(@as(usize, 2), s.path_adds.len);
    try testing.expectEqual(@as(usize, 2), s.files.len);
    // Формат приписывается к имени файла, чтобы было видно, как его прочтут.
    try testing.expectEqualStrings("extra.json (json)", s.files[1]);
}

// Пользователю обязаны показать, что одобрение разрешает вызов плагина, —
// в обеих записях секрета.
test "secrets appear in both spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a,
        \\schema = "envee/v1"
        \\[env]
        \\SHORTHAND = { source = "env", ref = "A" }
        \\[env._.secret.TABLE_FORM]
        \\source = "vault"
        \\ref = "B"
    );
    try testing.expectEqual(@as(usize, 2), s.secrets.len);
    // Отсортированы, чтобы вывод не менялся от запуска к запуску.
    try testing.expectEqualStrings("SHORTHAND = env://A", s.secrets[0]);
    try testing.expectEqualStrings("TABLE_FORM = vault://B", s.secrets[1]);
}

test "a sensitive-looking name without redact is a warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a, "schema = \"envee/v1\"\n[env]\nGITHUB_TOKEN = \"ghp_x\"\nPORT = 5432\n");
    try testing.expectEqual(@as(usize, 1), s.warnings.len);
    try testing.expect(std.mem.indexOf(u8, s.warnings[0], "GITHUB_TOKEN") != null);
    // Помеченное redact предупреждения не вызывает.
    const clean = try summaryOf(a, "schema = \"envee/v1\"\n[env]\nGITHUB_TOKEN = { value = \"x\", redact = true }\n");
    try testing.expectEqual(@as(usize, 0), clean.warnings.len);
}

test "scripts are called out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a, "schema = \"envee/v1\"\n[env]\n_.script = [{ path = \"a.wasm\" }]\n");
    try testing.expectEqual(@as(usize, 1), s.scripts);
    try testing.expect(std.mem.indexOf(u8, s.warnings[0], "script") != null);
}

test "meta keys are not counted as variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a, "schema = \"envee/v1\"\nprofile = \"dev\"\n[env]\nA = \"1\"\nwatch = [\"x\"]\n");
    try testing.expectEqual(@as(usize, 1), s.env_vars.len);
    try testing.expectEqualStrings("A", s.env_vars[0]);
}

test "rendering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s = try summaryOf(a,
        \\schema = "envee/v1"
        \\profile = "dev"
        \\[env]
        \\A = "1"
        \\_.path = ["./bin"]
    );
    var aw: Writer.Allocating = .init(a);
    try write(&aw.writer, s);
    const out = aw.written();

    try testing.expect(std.mem.startsWith(u8, out, "Trust /p/envee.toml\n"));
    try testing.expect(std.mem.indexOf(u8, out, "  Schema:     envee/v1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  Profile:    dev\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  Env vars:   1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  PATH adds:  1\n              - ./bin\n") != null);
}

test "nameLooksSensitive" {
    for ([_][]const u8{ "API_KEY", "GITHUB_TOKEN", "DB_PASSWORD", "MY_SECRET", "AWS_CREDENTIALS", "PRIVATE_KEY", "AUTH_HEADER" }) |k| {
        try testing.expect(nameLooksSensitive(k));
    }
    for ([_][]const u8{ "SERVICE_NAME", "PORT", "LOG_LEVEL", "DATABASE_URL" }) |k| {
        try testing.expect(!nameLooksSensitive(k));
    }
    // Совпадение по подстроке, без границ слова: перекос в сторону лишнего
    // предупреждения — сознательный, как и в Go.
    try testing.expect(nameLooksSensitive("MONKEY"));
    try testing.expect(nameLooksSensitive("AUTHOR"));
}
