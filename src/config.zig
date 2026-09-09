//! Схема `envee.toml` и её разбор поверх собственного парсера TOML.
//!
//! Порт `internal/config/config.go` и `internal/config/parse.go`.
//! См. docs/adr/0002-config-format-toml.md и docs/adr/0010-profiles.md.
//!
//! В Go разбор делал BurntSushi через теги структур, а всё, что в теги не
//! укладывалось, доставалось повторным проходом по «сырой» карте. Здесь
//! промежуточного слоя нет: дерево из toml/parser.zig и есть сырая карта, и
//! схема собирается из него одним проходом.
//!
//! Владение: `Config` живёт в той же арене, что и дерево TOML, и отдельных
//! строк не копирует. Освобождается всё вместе с ареной.

const std = @import("std");
const Allocator = std.mem.Allocator;

const toml = @import("toml/parser.zig");
const value = @import("toml/value.zig");

pub const Value = value.Value;
pub const Table = value.Table;

/// Версия схемы, подставляемая, когда файл её не объявил.
pub const schema_version = "envee/v1";

/// Ключи верхнего уровня, зарезервированные за самим envee: переменными
/// окружения они не становятся.
pub const meta_keys = [_][]const u8{
    "watch",               "extends", "required",
    "schema",              "profile", "stop_search_up",
    "profile_from_branch",
};

pub fn isMetaKey(k: []const u8) bool {
    for (meta_keys) |m| {
        if (std.mem.eql(u8, k, m)) return true;
    }
    return false;
}

/// Один файл, вложивший свой вклад в итоговый конфиг.
pub const SourceFile = struct {
    path: []const u8,
    /// Канонический хеш содержимого — та же строка, что записывает trust.
    hash: []const u8,
};

pub const FileRef = struct {
    path: []const u8 = "",
    /// "dotenv" (по умолчанию), "json", "yaml", "toml".
    format: []const u8 = "",
    required: bool = false,
    redact: bool = false,
    /// Раскрывать ли `$VAR` внутри значений.
    expand: bool = false,
};

pub const PathEntry = struct {
    path: []const u8 = "",
    /// "prepend" (по умолчанию) или "append".
    position: []const u8 = "",
};

pub const ScriptRef = struct {
    path: []const u8 = "",
    allow_env: []const []const u8 = &.{},
    allow_read: []const []const u8 = &.{},
    quota_cpu: []const u8 = "",
    quota_memory: []const u8 = "",
};

pub const SecretRef = struct {
    /// Имя плагина: "op", "aws", "vault", "env".
    source: []const u8 = "",
    /// Ссылка в терминах плагина.
    ref: []const u8 = "",
    account: []const u8 = "",
    vault: []const u8 = "",
    profile: []const u8 = "",
    redact: bool = false,
    required: bool = false,
};

pub const SourceRef = struct {
    path: []const u8 = "",
    shell: []const u8 = "",
    redact: bool = false,
};

/// Именованная ссылка на секрет. Хранится списком, а не картой: порядок
/// нужен для детерминированного вывода `envee status` и `envee check`.
pub const NamedSecret = struct {
    name: []const u8,
    ref: SecretRef,
};

/// Встроенные директивы из таблицы `[env._]`.
pub const Directives = struct {
    file: []const FileRef = &.{},
    path: []const PathEntry = &.{},
    script: []const ScriptRef = &.{},
    secret: []const NamedSecret = &.{},
    source: []const SourceRef = &.{},

    pub fn secretByName(d: Directives, name: []const u8) ?SecretRef {
        for (d.secret) |s| {
            if (std.mem.eql(u8, s.name, name)) return s.ref;
        }
        return null;
    }
};

/// Профиль: наложение поверх базовых переменных.
pub const Profile = struct {
    name: []const u8,
    /// Профили, применяемые до этого.
    extends: []const []const u8 = &.{},
    /// Переменные профиля. Значения остаются динамическими: приведение к
    /// строке делает directive, ему нужен исходный тип.
    env: *Table,
    directives: Directives = .{},
    /// Переменные, обязанные быть определёнными при активном профиле.
    required: []const []const u8 = &.{},
};

pub const Config = struct {
    /// Закреплённая версия схемы.
    schema: []const u8 = schema_version,
    /// Профиль по умолчанию, если $ENVEE_PROFILE не задан.
    profile: []const u8 = "",
    /// Не подниматься в родительские каталоги.
    stop_search_up: bool = false,
    /// Выводить профиль из имени ветки git.
    profile_from_branch: bool = false,

    /// Таблица `[env]` без служебных ключей и без `_`.
    env: *Table,
    profiles: []Profile = &.{},
    directives: Directives = .{},

    /// Путь к ПЕРВОМУ файлу. Остальные — в `sources`.
    path: []const u8 = "",
    /// Канонический хеш первого файла.
    file_hash: []const u8 = "",
    /// Время изменения первого файла, наносекунды.
    mod_time: i128 = 0,
    /// Дополнительные файлы, за изменением которых следит hook.
    watched_paths: []const []const u8 = &.{},

    /// Каждый файл, вложившийся в этот конфиг, в порядке слияния.
    ///
    /// `path` и `file_hash` описывают только ПЕРВЫЙ из них, поэтому проверка
    /// доверия обязана идти по этому списку. Иначе одобрен будет один файл,
    /// а применены все.
    sources: []const SourceFile = &.{},

    /// Имена переменных в отсортированном порядке.
    pub fn sortedKeys(c: Config, gpa: Allocator) Allocator.Error![]const []const u8 {
        const out = try gpa.dupe([]const u8, c.env.keys());
        std.mem.sort([]const u8, out, {}, lessThanSlice);
        return out;
    }

    pub fn profileByName(c: Config, name: []const u8) ?*const Profile {
        for (c.profiles) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Все объявленные секреты, из обеих поддерживаемых записей:
    ///
    ///     [env._.secret.DB_PASSWORD]      -> directives.secret
    ///     DB_PASSWORD = { source = ... }  -> сокращение внутри [env]
    ///
    /// Сокращение раскрывается только на этапе применения директив, поэтому
    /// всё, что смотрит на разобранный конфиг (сводка для доверия,
    /// `envee check`), обязано ходить сюда. Иначе оно пропустит сокращённые
    /// секреты — а для сводки это значит не сказать пользователю, что
    /// одобрение конфига разрешает вызов плагина.
    pub fn secretRefs(c: Config, gpa: Allocator) Allocator.Error![]const NamedSecret {
        var out: std.ArrayList(NamedSecret) = .empty;
        errdefer out.deinit(gpa);

        for (c.directives.secret) |s| try out.append(gpa, s);

        for (c.env.keys(), c.env.map.values()) |name, v| {
            if (std.mem.eql(u8, name, "_")) continue;
            const t = v.asTable() orelse continue;
            const source = (t.get("source") orelse continue).asString() orelse continue;
            if (source.len == 0) continue;

            var already = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) already = true;
            }
            if (already) continue;

            try out.append(gpa, .{ .name = name, .ref = .{
                .source = source,
                .ref = strOf(t.get("ref")),
                .redact = boolOf(t.get("redact")),
                .required = boolOf(t.get("required")),
            } });
        }
        return out.toOwnedSlice(gpa);
    }
};

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const Error = toml.Error;
pub const Diagnostics = toml.Diagnostics;

/// Разбирает конфиг из байтов. `path` попадает в сообщения об ошибках и в
/// записи trust; на диск не ходит.
pub fn parseBytes(
    arena: Allocator,
    path: []const u8,
    data: []const u8,
    diag: ?*Diagnostics,
) Error!Config {
    const root = try toml.parse(arena, data, diag);

    var c: Config = .{
        .env = try Table.create(arena),
        .path = path,
        .schema = strOf(root.get("schema")),
        .profile = strOf(root.get("profile")),
        .stop_search_up = boolOf(root.get("stop_search_up")),
        .profile_from_branch = boolOf(root.get("profile_from_branch")),
    };
    if (c.schema.len == 0) c.schema = schema_version;

    if (root.get("env")) |env_value| {
        if (env_value.asTable()) |env_table| {
            // Таблица `[env._]` — это директивы, а не переменная.
            if (env_table.get("_")) |underscore| {
                if (underscore.asTable()) |d| c.directives = try directivesFrom(arena, d);
            }
            // `watch` записывают внутри [env]; без этого подъёма список
            // оставался пустым, и hook не знал, за какими файлами следить,
            // то есть документированное «перезагружать при изменении» просто
            // не работало.
            if (env_table.get("watch")) |w| c.watched_paths = try strSliceOf(arena, w);

            for (env_table.keys(), env_table.map.values()) |k, v| {
                if (std.mem.eql(u8, k, "_") or std.mem.eql(u8, k, "watch")) continue;
                try c.env.put(arena, k, v);
            }
        }
    }

    if (root.get("profiles")) |profiles_value| {
        if (profiles_value.asTable()) |profiles_table| {
            c.profiles = try profilesFrom(arena, profiles_table);
        }
    }

    c.file_hash = try value.canonicalHash(arena, root);
    const sources = try arena.alloc(SourceFile, 1);
    sources[0] = .{ .path = path, .hash = c.file_hash };
    c.sources = sources;

    return c;
}

/// Читает и разбирает конфиг с диска.
pub fn parseFile(
    arena: Allocator,
    io: std.Io,
    path: []const u8,
    diag: ?*Diagnostics,
) !Config {
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, path, arena, .unlimited);
    var c = try parseBytes(arena, path, data, diag);
    if (cwd.statFile(io, path, .{})) |st| {
        c.mod_time = st.mtime.nanoseconds;
    } else |_| {}
    return c;
}

/// Собирает профили. Ключи, не входящие в служебный набор, считаются
/// переменными профиля: `[profiles.dev]` с `KEY = "v"` внутри — это то же,
/// что `[profiles.dev.env]` с тем же ключом.
fn profilesFrom(arena: Allocator, t: *const Table) Error![]Profile {
    var out: std.ArrayList(Profile) = .empty;

    for (t.keys(), t.map.values()) |name, raw| {
        const pt = raw.asTable() orelse continue;

        var p: Profile = .{ .name = name, .env = try Table.create(arena) };
        p.extends = try strSliceOf(arena, pt.get("extends"));
        p.required = try strSliceOf(arena, pt.get("required"));

        // Сначала вложенная таблица [profiles.X.env] …
        if (pt.get("env")) |env_value| {
            if (env_value.asTable()) |env_table| {
                for (env_table.keys(), env_table.map.values()) |k, v| {
                    if (std.mem.eql(u8, k, "_")) {
                        if (v.asTable()) |d| p.directives = try directivesFrom(arena, d);
                        continue;
                    }
                    try p.env.put(arena, k, v);
                }
            }
        }
        // … затем ключи, записанные прямо в [profiles.X]. При совпадении
        // побеждают они — так же, как в Go-эталоне.
        for (pt.keys(), pt.map.values()) |k, v| {
            if (isMetaKey(k) or std.mem.eql(u8, k, "env")) continue;
            try p.env.put(arena, k, v);
        }

        try out.append(arena, p);
    }
    return out.toOwnedSlice(arena);
}

/// Разбирает таблицу `[env._]`.
///
/// Каждая директива принимает несколько записей: одиночная строка там, где
/// ожидается список, — обычный способ написать `_.file = ".env"`.
fn directivesFrom(arena: Allocator, t: *const Table) Error!Directives {
    var d: Directives = .{};

    if (t.get("file")) |v| d.file = try fileRefs(arena, v);
    if (t.get("path")) |v| d.path = try pathEntries(arena, v);
    if (t.get("script")) |v| d.script = try scriptRefs(arena, v);
    if (t.get("secret")) |v| d.secret = try secretRefs(arena, v);
    if (t.get("source")) |v| d.source = try sourceRefs(arena, v);

    return d;
}

fn fileRefs(arena: Allocator, v: Value) Error![]const FileRef {
    var out: std.ArrayList(FileRef) = .empty;
    switch (v) {
        .string => |s| try out.append(arena, .{ .path = s }),
        .table => |t| try out.append(arena, fileRefFrom(t)),
        .array => |items| for (items) |item| {
            switch (item) {
                .string => |s| try out.append(arena, .{ .path = s }),
                .table => |t| try out.append(arena, fileRefFrom(t)),
                else => {},
            }
        },
        else => {},
    }
    return out.toOwnedSlice(arena);
}

fn fileRefFrom(t: *const Table) FileRef {
    return .{
        .path = strOf(t.get("path")),
        .format = strOf(t.get("format")),
        .required = boolOf(t.get("required")),
        .redact = boolOf(t.get("redact")),
        .expand = boolOf(t.get("expand")),
    };
}

fn pathEntries(arena: Allocator, v: Value) Error![]const PathEntry {
    var out: std.ArrayList(PathEntry) = .empty;
    switch (v) {
        .string => |s| try out.append(arena, .{ .path = s }),
        .array => |items| for (items) |item| {
            switch (item) {
                .string => |s| try out.append(arena, .{ .path = s }),
                .table => |t| try out.append(arena, .{
                    .path = strOf(t.get("path")),
                    .position = strOf(t.get("position")),
                }),
                else => {},
            }
        },
        else => {},
    }
    return out.toOwnedSlice(arena);
}

fn scriptRefs(arena: Allocator, v: Value) Error![]const ScriptRef {
    var out: std.ArrayList(ScriptRef) = .empty;
    const items = v.asArray() orelse return out.toOwnedSlice(arena);
    for (items) |item| {
        const t = item.asTable() orelse continue;
        try out.append(arena, .{
            .path = strOf(t.get("path")),
            .allow_env = try strSliceOf(arena, t.get("allow_env")),
            .allow_read = try strSliceOf(arena, t.get("allow_read")),
            .quota_cpu = strOf(t.get("quota_cpu")),
            .quota_memory = strOf(t.get("quota_memory")),
        });
    }
    return out.toOwnedSlice(arena);
}

fn secretRefs(arena: Allocator, v: Value) Error![]const NamedSecret {
    var out: std.ArrayList(NamedSecret) = .empty;
    const t = v.asTable() orelse return out.toOwnedSlice(arena);
    for (t.keys(), t.map.values()) |name, raw| {
        const st = raw.asTable() orelse continue;
        try out.append(arena, .{ .name = name, .ref = .{
            .source = strOf(st.get("source")),
            .ref = strOf(st.get("ref")),
            .account = strOf(st.get("account")),
            .vault = strOf(st.get("vault")),
            .profile = strOf(st.get("profile")),
            .redact = boolOf(st.get("redact")),
            .required = boolOf(st.get("required")),
        } });
    }
    return out.toOwnedSlice(arena);
}

fn sourceRefs(arena: Allocator, v: Value) Error![]const SourceRef {
    var out: std.ArrayList(SourceRef) = .empty;
    switch (v) {
        .string => |s| try out.append(arena, .{ .path = s }),
        .array => |items| for (items) |item| {
            switch (item) {
                .string => |s| try out.append(arena, .{ .path = s }),
                .table => |t| try out.append(arena, .{
                    .path = strOf(t.get("path")),
                    .shell = strOf(t.get("shell")),
                    .redact = boolOf(t.get("redact")),
                }),
                else => {},
            }
        },
        else => {},
    }
    return out.toOwnedSlice(arena);
}

// ---- мягкое чтение значений ------------------------------------------------
//
// Конфиг пишет человек, и неверный ТИП значения не должен ронять разбор:
// такие случаи ловит `envee check` с внятным сообщением. Go-эталон ведёт
// себя так же.

fn strOf(v: ?Value) []const u8 {
    const val = v orelse return "";
    return val.asString() orelse "";
}

fn boolOf(v: ?Value) bool {
    const val = v orelse return false;
    return val.asBool() orelse false;
}

/// Список строк. Одиночная строка принимается там, где ожидается список, —
/// так же, как это уже делают директивы file и path.
fn strSliceOf(arena: Allocator, v: ?Value) Error![]const []const u8 {
    const val = v orelse return &.{};
    switch (val) {
        .string => |s| {
            const out = try arena.alloc([]const u8, 1);
            out[0] = s;
            return out;
        },
        .array => |items| {
            var out: std.ArrayList([]const u8) = .empty;
            for (items) |item| {
                if (item.asString()) |s| try out.append(arena, s);
            }
            return out.toOwnedSlice(arena);
        },
        else => return &.{},
    }
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn parseTest(arena: Allocator, src: []const u8) Error!Config {
    return parseBytes(arena, "/tmp/test/envee.toml", src, null);
}

test "basic fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\schema = "envee/v1"
        \\profile = "dev"
        \\
        \\[env]
        \\DATABASE_URL = "postgres://localhost/mydb"
        \\PORT = 5432
        \\DEBUG = true
    );
    try testing.expectEqualStrings("envee/v1", c.schema);
    try testing.expectEqualStrings("dev", c.profile);
    try testing.expectEqualStrings("postgres://localhost/mydb", c.env.get("DATABASE_URL").?.asString().?);
    try testing.expectEqual(@as(i64, 5432), c.env.get("PORT").?.asInt().?);
    try testing.expectEqual(true, c.env.get("DEBUG").?.asBool().?);
    try testing.expectEqualStrings("/tmp/test/envee.toml", c.path);
}

test "the schema version defaults when the file omits it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "[env]\nA = \"1\"\n");
    try testing.expectEqualStrings(schema_version, c.schema);
}

test "the hash is canonical and present in sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "schema = \"envee/v1\"\n[env]\nKEY = \"value\"\n");
    try testing.expect(std.mem.startsWith(u8, c.file_hash, "sha256:"));
    try testing.expectEqual(@as(usize, 1), c.sources.len);
    try testing.expectEqualStrings(c.file_hash, c.sources[0].hash);
    try testing.expectEqualStrings(c.path, c.sources[0].path);

    // Переформатирование хеш не меняет — иначе конфиг требовал бы повторного
    // одобрения после каждой правки отступов.
    const reformatted = try parseTest(a, "# comment\nschema='envee/v1'\n\n[env]\nKEY   =   \"value\"\n");
    try testing.expectEqualStrings(c.file_hash, reformatted.file_hash);
}

test "profiles: nested env, inline keys and required" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\KEY = "base"
        \\
        \\[profiles.dev]
        \\KEY = "dev-value"
        \\
        \\[profiles.prod]
        \\required = ["KEY", "OTHER"]
        \\extends = ["common"]
        \\[profiles.prod.env]
        \\KEY = "prod-value"
    );
    try testing.expectEqual(@as(usize, 2), c.profiles.len);

    // Ключ, записанный прямо в [profiles.dev], — такая же переменная, как в
    // [profiles.dev.env].
    const dev = c.profileByName("dev").?;
    try testing.expectEqualStrings("dev-value", dev.env.get("KEY").?.asString().?);

    const prod = c.profileByName("prod").?;
    try testing.expectEqualStrings("prod-value", prod.env.get("KEY").?.asString().?);
    try testing.expectEqual(@as(usize, 2), prod.required.len);
    try testing.expectEqualStrings("KEY", prod.required[0]);
    try testing.expectEqual(@as(usize, 1), prod.extends.len);
    // Служебные ключи переменными не становятся.
    try testing.expect(prod.env.get("required") == null);
    try testing.expect(prod.env.get("extends") == null);

    try testing.expect(c.profileByName("nope") == null);
}

test "directives: file, path and their shorthand spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\KEY = "value"
        \\
        \\[env._]
        \\path = ["./bin", "./node_modules/.bin"]
        \\file = ".env"
    );
    try testing.expectEqual(@as(usize, 2), c.directives.path.len);
    try testing.expectEqualStrings("./bin", c.directives.path[0].path);
    // Одиночная строка принимается там, где ожидается список.
    try testing.expectEqual(@as(usize, 1), c.directives.file.len);
    try testing.expectEqualStrings(".env", c.directives.file[0].path);

    // Тот же смысл, записанный составным ключом и таблицами.
    const other = try parseTest(a,
        \\[env]
        \\_.file = [
        \\  { path = ".env", required = false },
        \\  { path = ".env.local", redact = true, expand = true },
        \\]
        \\_.path = [{ path = "./bin", position = "append" }]
    );
    try testing.expectEqual(@as(usize, 2), other.directives.file.len);
    try testing.expectEqualStrings(".env.local", other.directives.file[1].path);
    try testing.expect(other.directives.file[1].redact);
    try testing.expect(other.directives.file[1].expand);
    try testing.expect(!other.directives.file[0].required);
    try testing.expectEqualStrings("append", other.directives.path[0].position);
}

// Табличная запись секрета, описанная в ADR-0004, в Go долго не
// обрабатывалась вовсе и молча выбрасывалась: переменная не появлялась,
// status показывал ноль секретов, а check не находил, к чему придраться.
test "secrets: the table form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\APP = "x"
        \\
        \\[env._.secret.DB_PASSWORD]
        \\source = "vault"
        \\ref = "secret/data/db#password"
        \\redact = true
        \\required = true
    );
    const s = c.directives.secretByName("DB_PASSWORD").?;
    try testing.expectEqualStrings("vault", s.source);
    try testing.expectEqualStrings("secret/data/db#password", s.ref);
    try testing.expect(s.redact);
    try testing.expect(s.required);
}

test "secrets: optional fields survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env._.secret.TOKEN]
        \\source = "op"
        \\ref = "op://Dev/GitHub/token"
        \\account = "work"
        \\vault = "Dev"
        \\profile = "staging"
    );
    const s = c.directives.secretByName("TOKEN").?;
    try testing.expectEqualStrings("work", s.account);
    try testing.expectEqualStrings("Dev", s.vault);
    try testing.expectEqualStrings("staging", s.profile);
}

// Обе записи обязаны попадать в одно место: именно оттуда их берут сводка
// доверия, `envee check` и загрузка плагинов.
test "secretRefs covers both spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\SHORTHAND = { source = "env", ref = "A" }
        \\PLAIN = "not a secret"
        \\
        \\[env._.secret.TABLE_FORM]
        \\source = "vault"
        \\ref = "B"
    );
    const refs = try c.secretRefs(a);
    try testing.expectEqual(@as(usize, 2), refs.len);

    var saw_shorthand = false;
    var saw_table = false;
    for (refs) |r| {
        if (std.mem.eql(u8, r.name, "SHORTHAND")) {
            saw_shorthand = true;
            try testing.expectEqualStrings("env", r.ref.source);
        }
        if (std.mem.eql(u8, r.name, "TABLE_FORM")) {
            saw_table = true;
            try testing.expectEqualStrings("vault", r.ref.source);
        }
    }
    try testing.expect(saw_shorthand and saw_table);
}

test "the source directive, as a bare string and as a list of tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bare = try parseTest(a, "[env]\n_.source = \"setup.sh\"\n");
    try testing.expectEqual(@as(usize, 1), bare.directives.source.len);
    try testing.expectEqualStrings("setup.sh", bare.directives.source[0].path);

    const listed = try parseTest(a,
        \\[env]
        \\_.source = [ { path = "setup.sh", shell = "bash", redact = true } ]
    );
    try testing.expectEqual(@as(usize, 1), listed.directives.source.len);
    try testing.expectEqualStrings("setup.sh", listed.directives.source[0].path);
    try testing.expectEqualStrings("bash", listed.directives.source[0].shell);
    try testing.expect(listed.directives.source[0].redact);
}

test "the script directive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\_.script = [{ path = "s.wasm", allow_env = ["HOME"], allow_read = "/tmp", quota_cpu = "200ms" }]
    );
    try testing.expectEqual(@as(usize, 1), c.directives.script.len);
    try testing.expectEqualStrings("s.wasm", c.directives.script[0].path);
    try testing.expectEqualStrings("HOME", c.directives.script[0].allow_env[0]);
    // Одиночная строка вместо списка тоже принимается.
    try testing.expectEqual(@as(usize, 1), c.directives.script[0].allow_read.len);
    try testing.expectEqualStrings("200ms", c.directives.script[0].quota_cpu);
}

// Конфиг без директив не должен обзаводиться призрачными.
test "a config without directives gains none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "schema = \"envee/v1\"\n\n[env]\nA = \"1\"\n");
    try testing.expectEqual(@as(usize, 0), c.directives.secret.len);
    try testing.expectEqual(@as(usize, 0), c.directives.source.len);
    try testing.expectEqual(@as(usize, 0), c.directives.file.len);
    try testing.expectEqual(@as(usize, 0), c.directives.path.len);
    try testing.expectEqual(@as(usize, 0), (try c.secretRefs(a)).len);
}

// Список watch пишут внутри [env]. Пока его не поднимали, он оставался
// пустым, и документированное «перезагружать при изменении этих файлов»
// просто не работало.
test "watch is lifted out of the env table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\[env]
        \\A = "1"
        \\watch = ["Cargo.toml", "package.json"]
    );
    try testing.expectEqual(@as(usize, 2), c.watched_paths.len);
    try testing.expectEqualStrings("Cargo.toml", c.watched_paths[0]);
    // И переменной окружения при этом не становится.
    try testing.expect(c.env.get("watch") == null);
    try testing.expectEqual(@as(usize, 1), c.env.count());
}

test "the directive table is not an env variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "[env]\nA = \"1\"\n_.path = [\"./bin\"]\n");
    try testing.expect(c.env.get("_") == null);
    try testing.expectEqual(@as(usize, 1), c.env.count());
}

test "sortedKeys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "[env]\nZ = \"1\"\nA = \"2\"\nM = \"3\"\n");
    const keys = try c.sortedKeys(a);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("A", keys[0]);
    try testing.expectEqualStrings("M", keys[1]);
    try testing.expectEqualStrings("Z", keys[2]);
}

test "top-level flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a, "stop_search_up = true\nprofile_from_branch = true\n");
    try testing.expect(c.stop_search_up);
    try testing.expect(c.profile_from_branch);

    const d = try parseTest(a, "[env]\nA = \"1\"\n");
    try testing.expect(!d.stop_search_up);
    try testing.expect(!d.profile_from_branch);
}

test "invalid TOML is refused with a position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var diag: Diagnostics = .{};
    try testing.expectError(
        error.UnexpectedToken,
        parseBytes(a, "/tmp/envee.toml", "this is not = \"valid\" toml = =", &diag),
    );
    try testing.expectEqual(@as(usize, 1), diag.line);
}

// Конфиг пишет человек, и неверный тип значения не должен ронять разбор:
// такие случаи ловит `envee check` с внятным сообщением.
test "wrongly typed directive values are ignored, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = try parseTest(a,
        \\schema = 42
        \\[env]
        \\_.path = 17
        \\_.file = true
        \\_.secret = "not a table"
    );
    // Число вместо версии схемы читается как её отсутствие.
    try testing.expectEqualStrings(schema_version, c.schema);
    try testing.expectEqual(@as(usize, 0), c.directives.path.len);
    try testing.expectEqual(@as(usize, 0), c.directives.file.len);
    try testing.expectEqual(@as(usize, 0), c.directives.secret.len);
}

test "every example config in the repository loads" {
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

        const src = try dir.readFileAlloc(io, entry.path, a, .unlimited);
        var diag: Diagnostics = .{};
        const c = parseBytes(a, entry.path, src, &diag) catch |err| {
            std.debug.print("examples/{s}:{d}:{d}: {s} ({s})\n", .{
                entry.path, diag.line, diag.column, @errorName(err), diag.detail,
            });
            return err;
        };
        try testing.expectEqualStrings(schema_version, c.schema);
        try testing.expect(std.mem.startsWith(u8, c.file_hash, "sha256:"));
        found += 1;
    }
    try testing.expect(found >= 4);
}
