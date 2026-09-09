//! Хранилище одобрений конфигов.
//!
//! Порт `internal/trust/store.go` и `internal/trust/check.go`.
//! См. docs/adr/0004-trust-model.md.
//!
//! Запись хранится под именем, равным хешу СОДЕРЖИМОГО, поэтому любое
//! изменение файла делает одобрение недействительным — так и задумано.
//! Запрет, наоборот, хранится под хешом ПУТИ: запрещённый файл обязан
//! оставаться запрещённым и после правки.
//!
//! ВНИМАНИЕ, миграция. Записи получают `version: 2`, потому что канонический
//! хеш в Zig-версии считается иначе (см. toml/value.zig): воспроизвести
//! побайтно то, что делал BurntSushi при повторной сериализации, без самой
//! библиотеки невозможно. Записи первой версии читаются, но считаются
//! неизвестными: их хеш заведомо не сойдётся. На практике это значит один
//! повторный `envee trust` на проект при переходе с Go-версии.
//!
//! Владение: строки записи ссылаются на память вызывающего либо на арену.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Версия формата записи. См. примечание о миграции в шапке файла.
pub const entry_version: u32 = 2;

pub const Status = enum {
    /// Записи нет.
    unknown,
    trusted,
    denied,
    expired,

    pub fn name(s: Status) []const u8 {
        return @tagName(s);
    }
};

/// Подпись ed25519 поверх остальной записи. Появится на шаге 18; здесь она
/// нужна, чтобы читать и писать поле, не теряя его.
pub const Sig = struct {
    signed_at: []const u8 = "",
    algorithm: []const u8 = "",
    key_id: []const u8 = "",
    value: []const u8 = "",
};

pub const Entry = struct {
    signature: ?Sig = null,
    /// RFC3339 в UTC; пусто — не истекает.
    expires_at: []const u8 = "",
    trusted_at: []const u8 = "",
    file_hash: []const u8 = "",
    file_path: []const u8 = "",
    trusted_by: []const u8 = "",
    tool_version: []const u8 = "",
    comment: []const u8 = "",
    version: u32 = entry_version,
};

pub const Error = error{
    /// Файл записи есть, но разобрать его не удалось.
    CorruptEntry,
} || Allocator.Error || std.Io.Dir.ReadFileAllocError || std.Io.Dir.CreateDirPathError ||
    std.Io.Dir.WriteFileError || std.Io.Dir.RenameError ||
    std.Io.Dir.DeleteFileError || std.Io.Dir.OpenError;

pub const Store = struct {
    /// Каталог хранилища: `<data>/envee/trust`.
    root: []const u8,
    io: std.Io,
    /// Текущее время в наносекундах от эпохи. Поле, а не вызов на месте:
    /// тестам нужно проверять истечение срока, не ожидая его наступления.
    now_ns: i128,
    /// Кто одобряет — попадает в запись.
    user: []const u8,
    tool_version: []const u8,

    pub fn init(paths_trust_store: []const u8, io: std.Io, environ: *const std.process.Environ.Map, tool_version: []const u8) Store {
        return .{
            .root = paths_trust_store,
            .io = io,
            .now_ns = std.Io.Timestamp.now(io, .real).nanoseconds,
            .user = environ.get("USER") orelse (environ.get("USERNAME") orelse "unknown"),
            .tool_version = tool_version,
        };
    }

    /// Состояние файла с данным хешом содержимого.
    pub fn status(s: Store, arena: Allocator, file_path: []const u8, hash: []const u8) Error!Status {
        // Запрет проверяется ПЕРВЫМ и хранится по пути, а не по содержимому:
        // запрещённый файл обязан оставаться запрещённым и после правки.
        // Явный запрет сильнее любого одобрения, которое могло остаться для
        // текущего содержимого.
        if (try s.isDenied(arena, file_path)) return .denied;

        const entry = (try s.get(arena, hash)) orelse return .unknown;

        // Записи первой версии считались по другому канону, их хеш заведомо
        // не сойдётся; не притворяемся, что понимаем их.
        if (entry.version < entry_version) return .unknown;

        if (entry.expires_at.len > 0) {
            const expires = parseRfc3339(entry.expires_at) orelse return .unknown;
            if (s.now_ns > expires) return .expired;
        }
        return .trusted;
    }

    pub fn isTrusted(s: Store, arena: Allocator, file_path: []const u8, hash: []const u8) bool {
        return (s.status(arena, file_path, hash) catch return false) == .trusted;
    }

    /// Собирает запись, не сохраняя её.
    ///
    /// Отдельно от `put`, потому что подпись покрывает готовую запись, и
    /// подписывать надо между сборкой и сохранением.
    pub fn newEntry(s: Store, arena: Allocator, file_path: []const u8, hash: []const u8, ttl_ns: i128) Allocator.Error!Entry {
        return .{
            .version = entry_version,
            .file_hash = hash,
            .file_path = file_path,
            .trusted_at = try formatRfc3339(arena, s.now_ns),
            .trusted_by = s.user,
            .tool_version = s.tool_version,
            .expires_at = if (ttl_ns > 0) try formatRfc3339(arena, s.now_ns + ttl_ns) else "",
        };
    }

    /// Записывает одобрение и снимает запрет с того же пути: одобрить файл
    /// и оставить его запрещённым было бы противоречием.
    pub fn put(s: Store, arena: Allocator, e: Entry) Error!void {
        try s.undeny(arena, e.file_path);
        try s.writeEntry(arena, e);
    }

    pub fn trust(s: Store, arena: Allocator, file_path: []const u8, hash: []const u8, ttl_ns: i128) Error!Entry {
        const e = try s.newEntry(arena, file_path, hash, ttl_ns);
        try s.put(arena, e);
        return e;
    }

    pub fn get(s: Store, arena: Allocator, hash: []const u8) Error!?Entry {
        const path = try s.entryPath(arena, hash);
        const data = std.Io.Dir.cwd().readFileAlloc(s.io, path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return parseEntry(arena, data) catch error.CorruptEntry;
    }

    pub fn revoke(s: Store, arena: Allocator, hash: []const u8) Error!void {
        const path = try s.entryPath(arena, hash);
        std.Io.Dir.cwd().deleteFile(s.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn deny(s: Store, arena: Allocator, file_path: []const u8) Error!void {
        const path = try s.denyPath(arena, file_path);
        if (std.fs.path.dirname(path)) |dir| {
            _ = try std.Io.Dir.cwd().createDirPathStatus(s.io, dir, .fromMode(0o700));
        }
        const body = try std.fmt.allocPrint(arena, "{s}\n", .{file_path});
        try std.Io.Dir.cwd().writeFile(s.io, .{
            .sub_path = path,
            .data = body,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }

    pub fn undeny(s: Store, arena: Allocator, file_path: []const u8) Error!void {
        const path = try s.denyPath(arena, file_path);
        std.Io.Dir.cwd().deleteFile(s.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Все записи хранилища, свежие первыми.
    ///
    /// Отсутствие каталога — не ошибка: значит, ещё ничего не одобряли.
    pub fn list(s: Store, arena: Allocator) Error![]const Entry {
        var out: std.ArrayList(Entry) = .empty;
        var dir = std.Io.Dir.cwd().openDir(s.io, s.root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return out.toOwnedSlice(arena),
            else => return err,
        };
        defer dir.close(s.io);

        var it = dir.iterate();
        while (it.next(s.io) catch null) |ent| {
            if (ent.kind == .directory) continue;
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const data = dir.readFileAlloc(s.io, ent.name, arena, .unlimited) catch continue;
            const e = parseEntry(arena, data) catch continue;
            try out.append(arena, e);
        }
        const items = try out.toOwnedSlice(arena);
        std.mem.sort(Entry, @constCast(items), {}, newestFirst);
        return items;
    }

    fn isDenied(s: Store, arena: Allocator, file_path: []const u8) Error!bool {
        const path = try s.denyPath(arena, file_path);
        _ = std.Io.Dir.cwd().statFile(s.io, path, .{}) catch return false;
        return true;
    }

    fn entryPath(s: Store, arena: Allocator, hash: []const u8) Allocator.Error![]const u8 {
        const name = try std.fmt.allocPrint(arena, "{s}.json", .{stripPrefix(hash)});
        return std.fs.path.join(arena, &.{ s.root, name });
    }

    fn denyPath(s: Store, arena: Allocator, file_path: []const u8) Allocator.Error![]const u8 {
        const name = try std.fmt.allocPrint(arena, "{s}.json", .{pathHash(file_path)});
        return std.fs.path.join(arena, &.{ s.root, "deny", name });
    }

    /// Пишет запись атомарно: сначала во временный файл, потом переименование.
    ///
    /// Иначе прерванная запись оставила бы обрезанный JSON, и при следующем
    /// запуске одобрение бесследно пропало бы.
    fn writeEntry(s: Store, arena: Allocator, e: Entry) Error!void {
        const cwd = std.Io.Dir.cwd();
        // Права 0700: хранилище решает, какому коду позволено попасть в
        // окружение пользователя.
        _ = try cwd.createDirPathStatus(s.io, s.root, .fromMode(0o700));

        var body: Writer.Allocating = .init(arena);
        // Writer здесь свой и пишет в память: единственная настоящая причина
        // отказа — нехватка памяти.
        writeEntryJson(&body.writer, e) catch return error.OutOfMemory;

        var random_bytes: [8]u8 = undefined;
        s.io.random(&random_bytes);
        const tmp_name = try std.fmt.allocPrint(arena, "trust-{x}.json.tmp", .{&random_bytes});
        const tmp_path = try std.fs.path.join(arena, &.{ s.root, tmp_name });

        try cwd.writeFile(s.io, .{
            .sub_path = tmp_path,
            .data = body.written(),
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        errdefer cwd.deleteFile(s.io, tmp_path) catch {};

        const final = try s.entryPath(arena, e.file_hash);
        try cwd.rename(tmp_path, cwd, final, s.io);
    }
};

fn newestFirst(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.trusted_at, b.trusted_at) == .gt;
}

/// Имя файла записи — хеш без префикса `sha256:`.
fn stripPrefix(hash: []const u8) []const u8 {
    const prefix = "sha256:";
    if (std.mem.startsWith(u8, hash, prefix)) return hash[prefix.len..];
    return hash;
}

/// Имя файла запрета — sha256 от пути. Путь и перевод строки, как в Go.
fn pathHash(p: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(p);
    hasher.update("\n");
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

// ---- сериализация ----------------------------------------------------------

/// Пишет запись в том же виде, что и Go: отступ в два пробела, порядок полей
/// как в структуре, пустые необязательные поля опускаются.
pub fn writeEntryJson(w: *Writer, e: Entry) Writer.Error!void {
    try w.writeAll("{\n");
    var first = true;

    if (e.signature) |sig| {
        try w.writeAll("  \"signature\": {\n    \"signed_at\": ");
        try std.json.Stringify.value(sig.signed_at, .{}, w);
        try w.writeAll(",\n    \"algorithm\": ");
        try std.json.Stringify.value(sig.algorithm, .{}, w);
        try w.writeAll(",\n    \"key_id\": ");
        try std.json.Stringify.value(sig.key_id, .{}, w);
        try w.writeAll(",\n    \"value\": ");
        try std.json.Stringify.value(sig.value, .{}, w);
        try w.writeAll("\n  }");
        first = false;
    }
    if (e.expires_at.len > 0) {
        try field(w, &first, "expires_at", e.expires_at);
    }
    try field(w, &first, "trusted_at", e.trusted_at);
    try field(w, &first, "file_hash", e.file_hash);
    try field(w, &first, "file_path", e.file_path);
    try field(w, &first, "trusted_by", e.trusted_by);
    try field(w, &first, "tool_version", e.tool_version);
    if (e.comment.len > 0) try field(w, &first, "comment", e.comment);

    if (!first) try w.writeAll(",\n");
    try w.print("  \"version\": {d}\n}}\n", .{e.version});
}

fn field(w: *Writer, first: *bool, name: []const u8, value: []const u8) Writer.Error!void {
    if (!first.*) try w.writeAll(",\n");
    first.* = false;
    try w.print("  \"{s}\": ", .{name});
    try std.json.Stringify.value(value, .{}, w);
}

const StoredEntry = struct {
    signature: ?Sig = null,
    expires_at: []const u8 = "",
    trusted_at: []const u8 = "",
    file_hash: []const u8 = "",
    file_path: []const u8 = "",
    trusted_by: []const u8 = "",
    tool_version: []const u8 = "",
    comment: []const u8 = "",
    version: u32 = 1,
};

pub fn parseEntry(arena: Allocator, data: []const u8) !Entry {
    const parsed = try std.json.parseFromSliceLeaky(StoredEntry, arena, data, .{
        .ignore_unknown_fields = true,
    });
    return .{
        .signature = parsed.signature,
        .expires_at = parsed.expires_at,
        .trusted_at = parsed.trusted_at,
        .file_hash = parsed.file_hash,
        .file_path = parsed.file_path,
        .trusted_by = parsed.trusted_by,
        .tool_version = parsed.tool_version,
        .comment = parsed.comment,
        .version = parsed.version,
    };
}

// ---- время -----------------------------------------------------------------
//
// Только UTC и только секунды: `YYYY-MM-DDTHH:MM:SSZ`. Записи пишем и читаем
// мы сами, часовые пояса и доли секунды здесь не нужны, а полноценный разбор
// RFC3339 стоил бы заметно дороже.

pub fn formatRfc3339(arena: Allocator, ns: i128) Allocator.Error![]const u8 {
    const secs: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    if (secs < 0) return arena.dupe(u8, "1970-01-01T00:00:00Z");

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time_of_day = epoch.getDaySeconds();

    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        time_of_day.getHoursIntoDay(),
        time_of_day.getMinutesIntoHour(),
        time_of_day.getSecondsIntoMinute(),
    });
}

/// Разбирает `YYYY-MM-DDTHH:MM:SSZ` в наносекунды от эпохи.
/// null — форма не та; вызывающий обязан решить, что это значит.
pub fn parseRfc3339(s: []const u8) ?i128 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or
        s[13] != ':' or s[16] != ':') return null;

    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (std.time.epoch.isLeapYear(y)) 366 else 365;
    }
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += @as(i64, day) - 1;

    const secs = days * std.time.s_per_day +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return @as(i128, secs) * std.time.ns_per_s;
}

/// Разбирает срок жизни одобрения: `24h`, `7d`, `never`.
pub fn parseTtl(s: []const u8) ?i128 {
    if (s.len == 0 or std.mem.eql(u8, s, "never")) return 0;

    const unit = s[s.len - 1];
    const number = s[0 .. s.len - 1];
    const value = std.fmt.parseInt(i64, number, 10) catch return null;
    if (value < 0) return null;

    const multiplier: i128 = switch (unit) {
        's' => std.time.ns_per_s,
        'm' => std.time.ns_per_min,
        'h' => std.time.ns_per_hour,
        'd' => std.time.ns_per_day,
        else => return null,
    };
    return @as(i128, value) * multiplier;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const test_io = std.testing.io;

const TempStore = struct {
    root: []const u8,
    store: Store,

    fn create(gpa: Allocator, now_ns: i128) !TempStore {
        const cwd_path = try std.process.currentPathAlloc(test_io, gpa);
        var random_bytes: [12]u8 = undefined;
        test_io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const root = try std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &name, "trust" });

        return .{ .root = root, .store = .{
            .root = root,
            .io = test_io,
            .now_ns = now_ns,
            .user = "alice",
            .tool_version = "0.4.0-test",
        } };
    }

    fn destroy(t: TempStore) void {
        if (std.fs.path.dirname(t.root)) |parent| {
            std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
        }
    }
};

const hour_ns: i128 = std.time.ns_per_hour;
const base_now: i128 = 1_757_000_000 * @as(i128, std.time.ns_per_s);

test "an unknown file is not trusted, a trusted one is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    try testing.expectEqual(Status.unknown, try ts.store.status(a, "/p/envee.toml", "sha256:abc"));

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", 0);
    try testing.expectEqual(Status.trusted, try ts.store.status(a, "/p/envee.toml", "sha256:abc"));
    try testing.expect(ts.store.isTrusted(a, "/p/envee.toml", "sha256:abc"));

    // Одобрение привязано к СОДЕРЖИМОМУ: другой хеш — снова неизвестно.
    try testing.expectEqual(Status.unknown, try ts.store.status(a, "/p/envee.toml", "sha256:changed"));
}

test "a TTL expires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", hour_ns);
    try testing.expectEqual(Status.trusted, try ts.store.status(a, "/p/envee.toml", "sha256:abc"));

    // То же хранилище, но время ушло вперёд на два часа.
    var later = ts.store;
    later.now_ns = base_now + 2 * hour_ns;
    try testing.expectEqual(Status.expired, try later.status(a, "/p/envee.toml", "sha256:abc"));
}

test "revoke removes the approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", 0);
    try ts.store.revoke(a, "sha256:abc");
    try testing.expectEqual(Status.unknown, try ts.store.status(a, "/p/envee.toml", "sha256:abc"));

    // Повторный отзыв не ошибка.
    try ts.store.revoke(a, "sha256:abc");
}

// Запрет хранится по пути, а не по содержимому: запрещённый файл обязан
// оставаться запрещённым и после правки.
test "deny survives an edit and outranks an approval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", 0);
    try ts.store.deny(a, "/p/envee.toml");

    // Явный запрет сильнее оставшегося одобрения.
    try testing.expectEqual(Status.denied, try ts.store.status(a, "/p/envee.toml", "sha256:abc"));
    // И переживает изменение содержимого.
    try testing.expectEqual(Status.denied, try ts.store.status(a, "/p/envee.toml", "sha256:edited"));

    // Одобрение снимает запрет: иначе получилось бы противоречие.
    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:edited", 0);
    try testing.expectEqual(Status.trusted, try ts.store.status(a, "/p/envee.toml", "sha256:edited"));
}

test "entries round-trip through disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    const written = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", hour_ns);
    const read = (try ts.store.get(a, "sha256:abc")).?;

    try testing.expectEqualStrings(written.file_hash, read.file_hash);
    try testing.expectEqualStrings(written.file_path, read.file_path);
    try testing.expectEqualStrings(written.trusted_at, read.trusted_at);
    try testing.expectEqualStrings(written.expires_at, read.expires_at);
    try testing.expectEqualStrings("alice", read.trusted_by);
    try testing.expectEqualStrings("0.4.0-test", read.tool_version);
    try testing.expectEqual(entry_version, read.version);
    try testing.expect(read.signature == null);

    try testing.expect((try ts.store.get(a, "sha256:nothing")) == null);
}

// Записи, оставшиеся от Go-версии, считались по другому канону: их хеш
// заведомо не сойдётся, и притворяться, что мы их понимаем, нельзя.
test "a version 1 entry is treated as unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try std.Io.Dir.cwd().createDirPathStatus(test_io, ts.root, .fromMode(0o700));
    const path = try std.fs.path.join(a, &.{ ts.root, "legacy.json" });
    try std.Io.Dir.cwd().writeFile(test_io, .{
        .sub_path = path,
        .data =
        \\{
        \\  "trusted_at": "2026-01-01T00:00:00Z",
        \\  "file_hash": "sha256:legacy",
        \\  "file_path": "/p/envee.toml",
        \\  "version": 1
        \\}
        ,
    });
    try testing.expectEqual(Status.unknown, try ts.store.status(a, "/p/envee.toml", "sha256:legacy"));
}

test "list returns entries newest first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    // Пустое хранилище — не ошибка, просто ещё ничего не одобряли.
    try testing.expectEqual(@as(usize, 0), (try ts.store.list(a)).len);

    var older = ts.store;
    older.now_ns = base_now;
    _ = try older.trust(a, "/p/old.toml", "sha256:old", 0);

    var newer = ts.store;
    newer.now_ns = base_now + 100 * hour_ns;
    _ = try newer.trust(a, "/p/new.toml", "sha256:new", 0);

    const items = try ts.store.list(a);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("/p/new.toml", items[0].file_path);
    try testing.expectEqualStrings("/p/old.toml", items[1].file_path);
}

// Прерванная запись не должна оставлять обрезанный JSON: одобрение
// пропало бы бесследно.
test "the entry file has restrictive permissions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:abc", 0);

    const path = try std.fs.path.join(a, &.{ ts.root, "abc.json" });
    const st = try std.Io.Dir.cwd().statFile(test_io, path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    const dir_st = try std.Io.Dir.cwd().statFile(test_io, ts.root, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_st.permissions.toMode() & 0o777);

    // Временных файлов после успешной записи остаться не должно.
    var dir = try std.Io.Dir.cwd().openDir(test_io, ts.root, .{ .iterate = true });
    defer dir.close(test_io);
    var it = dir.iterate();
    while (try it.next(test_io)) |e| {
        try testing.expect(std.mem.indexOf(u8, e.name, ".tmp") == null);
    }
}

test "the entry file name is the hash without its prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    _ = try ts.store.trust(a, "/p/envee.toml", "sha256:deadbeef", 0);
    const path = try std.fs.path.join(a, &.{ ts.root, "deadbeef.json" });
    _ = try std.Io.Dir.cwd().statFile(test_io, path, .{});
}

test "RFC3339 round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const u8{
        "1970-01-01T00:00:00Z",
        "2026-09-09T12:34:56Z",
        "2024-02-29T23:59:59Z", // високосный год
        "2000-01-01T00:00:00Z",
    };
    for (cases) |want| {
        const ns = parseRfc3339(want).?;
        const got = try formatRfc3339(a, ns);
        testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("round trip failed for {s}\n", .{want});
            return err;
        };
    }
    // Мусор не разбирается.
    try testing.expect(parseRfc3339("not a time") == null);
    try testing.expect(parseRfc3339("2026-13-01T00:00:00Z") == null);
    try testing.expect(parseRfc3339("") == null);
}

test "TTL parsing" {
    try testing.expectEqual(@as(i128, 0), parseTtl("never").?);
    try testing.expectEqual(@as(i128, 0), parseTtl("").?);
    try testing.expectEqual(@as(i128, 24 * std.time.ns_per_hour), parseTtl("24h").?);
    try testing.expectEqual(@as(i128, 7 * std.time.ns_per_day), parseTtl("7d").?);
    try testing.expectEqual(@as(i128, 30 * std.time.ns_per_min), parseTtl("30m").?);
    try testing.expect(parseTtl("nonsense") == null);
    try testing.expect(parseTtl("-1h") == null);
    try testing.expect(parseTtl("24") == null);
}

test "the serialized entry omits empty optional fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: Writer.Allocating = .init(a);
    try writeEntryJson(&aw.writer, .{
        .trusted_at = "2026-09-09T00:00:00Z",
        .file_hash = "sha256:abc",
        .file_path = "/p/envee.toml",
        .trusted_by = "alice",
        .tool_version = "0.4.0",
    });
    try testing.expectEqualStrings(
        \\{
        \\  "trusted_at": "2026-09-09T00:00:00Z",
        \\  "file_hash": "sha256:abc",
        \\  "file_path": "/p/envee.toml",
        \\  "trusted_by": "alice",
        \\  "tool_version": "0.4.0",
        \\  "version": 2
        \\}
        \\
    , aw.written());

    // И читается обратно.
    const back = try parseEntry(a, aw.written());
    try testing.expectEqualStrings("sha256:abc", back.file_hash);
    try testing.expect(back.expires_at.len == 0);
}

test "deny entries live under their own directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try TempStore.create(a, base_now);
    defer ts.destroy();

    try ts.store.deny(a, "/p/envee.toml");
    const dir = try std.fs.path.join(a, &.{ ts.root, "deny" });
    const st = try std.Io.Dir.cwd().statFile(test_io, dir, .{});
    try testing.expectEqual(std.Io.File.Kind.directory, st.kind);

    // Снятие запрета идемпотентно.
    try ts.store.undeny(a, "/p/envee.toml");
    try ts.store.undeny(a, "/p/envee.toml");
    try testing.expectEqual(Status.unknown, try ts.store.status(a, "/p/envee.toml", "sha256:x"));
}
