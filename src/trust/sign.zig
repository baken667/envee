//! Подпись записей доверия ключом ed25519.
//!
//! Порт `internal/trust/sign.go`. Подписанную запись можно передать коллеге:
//! рецензент подписывает своё одобрение конфига, остальные проверяют подпись
//! по его публичному ключу вместо того, чтобы читать файл заново.
//! См. docs/adr/0004-trust-model.md.
//!
//! Подписываемые байты собираются ТОЧНО как в Go: компактный JSON, ключи по
//! алфавиту, без поля `signature`. Особенности, без которых подписи Go и Zig
//! не сойдутся:
//!   - `expires_at` присутствует всегда; бессрочная запись несёт нулевое
//!     время Go, `0001-01-01T00:00:00Z` (у `time.Time` нет пустого значения,
//!     и `omitempty` его не убирает);
//!   - `comment` опускается, если пуст;
//!   - `version` — число.
//! Это проверяется фикстурой, подписанной настоящей Go-версией
//! (см. testdata/README.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Ed25519 = std.crypto.sign.Ed25519;

const store = @import("store.zig");
const ssh_key = @import("ssh_key.zig");

pub const algorithm = "ed25519";

/// Нулевое время Go — так оно сериализует `time.Time{}`.
pub const go_zero_time = "0001-01-01T00:00:00Z";

pub const Error = error{
    /// Запись не подписана.
    NoSignature,
    /// Подпись сделана другим алгоритмом.
    AlgorithmMismatch,
    /// Подпись сделана другим ключом.
    KeyMismatch,
    /// Подпись не декодируется.
    BadEncoding,
    /// Подпись не сходится: запись изменена или подписана для другого конфига.
    BadSignature,
    /// Приватный ключ отвергнут криптографией.
    BadKey,
} || Allocator.Error;

/// Отпечаток публичного ключа — сообщает читателю, какой ключ поставил подпись.
pub fn keyId(arena: Allocator, public: ssh_key.PublicBytes) Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&public, &digest, .{});
    return std.fmt.allocPrint(arena, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

/// Детерминированный JSON, который покрывает подпись: все поля записи,
/// кроме самой подписи, ключи по алфавиту.
///
/// Порядок полей структуры в подписываемые байты не входит намеренно:
/// иначе перестановка полей — изменение без смысла — обесценила бы все
/// существующие подписи.
pub fn signingPayload(arena: Allocator, e: store.Entry) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    // Writer свой и пишет в память: единственная причина отказа — память.
    payloadInner(w, e) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn payloadInner(w: *Writer, e: store.Entry) Writer.Error!void {
    try w.writeByte('{');
    var first = true;
    if (e.comment.len > 0) try jsonField(w, &first, "comment", e.comment);
    try jsonField(w, &first, "expires_at", if (e.expires_at.len > 0) e.expires_at else go_zero_time);
    try jsonField(w, &first, "file_hash", e.file_hash);
    try jsonField(w, &first, "file_path", e.file_path);
    try jsonField(w, &first, "tool_version", e.tool_version);
    try jsonField(w, &first, "trusted_at", e.trusted_at);
    try jsonField(w, &first, "trusted_by", e.trusted_by);
    if (!first) try w.writeByte(',');
    try w.print("\"version\":{d}", .{e.version});
    try w.writeByte('}');
}

fn jsonField(w: *Writer, first: *bool, name: []const u8, value: []const u8) Writer.Error!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.print("\"{s}\":", .{name});
    try std.json.Stringify.value(value, .{}, w);
}

/// Подписывает запись на месте. `signed_at` — RFC3339 в UTC.
pub fn signEntry(
    arena: Allocator,
    e: *store.Entry,
    secret: ssh_key.SecretBytes,
    signed_at: []const u8,
) Error!void {
    const sk = Ed25519.SecretKey.fromBytes(secret) catch return error.BadKey;
    const kp = Ed25519.KeyPair.fromSecretKey(sk) catch return error.BadKey;

    const payload = try signingPayload(arena, e.*);
    const sig = kp.sign(payload, null) catch return error.BadKey;
    const sig_bytes = sig.toBytes();

    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(sig_bytes.len));
    _ = encoder.encode(encoded, &sig_bytes);

    e.signature = .{
        .signed_at = signed_at,
        .algorithm = algorithm,
        .key_id = try keyId(arena, kp.public_key.toBytes()),
        .value = encoded,
    };
}

/// Проверяет подпись записи по публичному ключу.
pub fn verifyEntry(arena: Allocator, e: store.Entry, public: ssh_key.PublicBytes) Error!void {
    const sig = e.signature orelse return error.NoSignature;
    if (!std.mem.eql(u8, sig.algorithm, algorithm)) return error.AlgorithmMismatch;

    const want_id = try keyId(arena, public);
    if (!std.mem.eql(u8, sig.key_id, want_id)) return error.KeyMismatch;

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(sig.value) catch return error.BadEncoding;
    if (size != Ed25519.Signature.encoded_length) return error.BadEncoding;
    var raw: [Ed25519.Signature.encoded_length]u8 = undefined;
    decoder.decode(&raw, sig.value) catch return error.BadEncoding;

    const payload = try signingPayload(arena, e);
    const pk = Ed25519.PublicKey.fromBytes(public) catch return error.BadKey;
    Ed25519.Signature.fromBytes(raw).verify(payload, pk) catch return error.BadSignature;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn testEntry() store.Entry {
    return .{
        .version = 1,
        .file_hash = "sha256:abc123",
        .file_path = "/home/alice/proj/envee.toml",
        .trusted_at = "2026-09-08T12:00:00Z",
        .trusted_by = "alice",
        .tool_version = "0.2.0",
    };
}

// Байты подписи обязаны совпасть с Go до последнего символа — иначе никакая
// перекрёстная проверка невозможна. Ожидаемые строки сняты с Go-версии.
test "the signing payload matches Go byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "{\"expires_at\":\"0001-01-01T00:00:00Z\",\"file_hash\":\"sha256:abc123\"," ++
            "\"file_path\":\"/home/alice/proj/envee.toml\",\"tool_version\":\"0.2.0\"," ++
            "\"trusted_at\":\"2026-09-08T12:00:00Z\",\"trusted_by\":\"alice\",\"version\":1}",
        try signingPayload(a, testEntry()),
    );

    var with_extras = testEntry();
    with_extras.expires_at = "2026-12-31T23:59:59Z";
    with_extras.comment = "reviewed";
    try testing.expectEqualStrings(
        "{\"comment\":\"reviewed\",\"expires_at\":\"2026-12-31T23:59:59Z\",\"file_hash\":\"sha256:abc123\"," ++
            "\"file_path\":\"/home/alice/proj/envee.toml\",\"tool_version\":\"0.2.0\"," ++
            "\"trusted_at\":\"2026-09-08T12:00:00Z\",\"trusted_by\":\"alice\",\"version\":1}",
        try signingPayload(a, with_extras),
    );

    // Подпись в байты не входит: подписанная и неподписанная запись дают
    // одно и то же.
    var signed = testEntry();
    signed.signature = .{ .algorithm = "ed25519", .key_id = "x", .value = "y", .signed_at = "z" };
    try testing.expectEqualStrings(try signingPayload(a, testEntry()), try signingPayload(a, signed));
}

// Единственная независимая проверка: запись подписана НАСТОЯЩЕЙ Go-версией.
// Если она сходится, значит и разбор ключа OpenSSH, и сборка байтов, и
// отпечаток ключа сделаны в точности как там.
test "a Go-signed entry verifies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const public = try ssh_key.parsePublicKey(a, @embedFile("testdata/go_signed.pub"));
    const entry = try store.parseEntry(a, @embedFile("testdata/go_signed.json"));

    try testing.expect(entry.signature != null);
    try testing.expectEqualStrings(entry.signature.?.key_id, try keyId(a, public));
    try verifyEntry(a, entry, public);

    // А подделка — не сходится.
    var tampered = entry;
    tampered.file_hash = "sha256:tampered";
    try testing.expectError(error.BadSignature, verifyEntry(a, tampered, public));
}

test "sign and verify round-trip with a real ssh-keygen pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const keys = (try ssh_key.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);
    const secret = try ssh_key.loadPrivateKey(a, io, keys.private);
    const public = try ssh_key.loadPublicKey(a, io, keys.public);

    var e = testEntry();
    try signEntry(a, &e, secret, "2026-09-09T10:00:00Z");

    const sig = e.signature.?;
    try testing.expectEqualStrings(algorithm, sig.algorithm);
    try testing.expect(std.mem.startsWith(u8, sig.key_id, "sha256:"));
    try testing.expectEqualStrings("2026-09-09T10:00:00Z", sig.signed_at);
    try verifyEntry(a, e, public);

    // Через диск: запись сериализуется, читается и всё ещё сходится.
    var aw: Writer.Allocating = .init(a);
    try store.writeEntryJson(&aw.writer, e);
    const back = try store.parseEntry(a, aw.written());
    try verifyEntry(a, back, public);
}

// Смысл подписи в том, что она привязана к содержимому. Любая правка обязана
// её обесценить.
test "tampering with any field invalidates the signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const keys = (try ssh_key.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);
    const secret = try ssh_key.loadPrivateKey(a, io, keys.private);
    const public = try ssh_key.loadPublicKey(a, io, keys.public);

    const Mutation = struct { name: []const u8, apply: *const fn (*store.Entry) void };
    const mutations = [_]Mutation{
        .{ .name = "hash", .apply = struct {
            fn f(e: *store.Entry) void {
                e.file_hash = "sha256:tampered";
            }
        }.f },
        .{ .name = "path", .apply = struct {
            fn f(e: *store.Entry) void {
                e.file_path = "/tmp/evil/envee.toml";
            }
        }.f },
        .{ .name = "expiry", .apply = struct {
            fn f(e: *store.Entry) void {
                e.expires_at = "2099-01-01T00:00:00Z";
            }
        }.f },
        .{ .name = "trusted_by", .apply = struct {
            fn f(e: *store.Entry) void {
                e.trusted_by = "mallory";
            }
        }.f },
        .{ .name = "comment", .apply = struct {
            fn f(e: *store.Entry) void {
                e.comment = "looks fine to me";
            }
        }.f },
        .{ .name = "version", .apply = struct {
            fn f(e: *store.Entry) void {
                e.version = 2;
            }
        }.f },
    };
    for (mutations) |m| {
        var e = testEntry();
        try signEntry(a, &e, secret, "2026-09-09T10:00:00Z");
        m.apply(&e);
        testing.expectError(error.BadSignature, verifyEntry(a, e, public)) catch |err| {
            std.debug.print("modifying {s} must invalidate the signature\n", .{m.name});
            return err;
        };
    }
}

test "the wrong key, a missing signature and a foreign algorithm are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const keys = (try ssh_key.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);
    const other = (try ssh_key.KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer other.destroy(io);

    const secret = try ssh_key.loadPrivateKey(a, io, keys.private);
    const other_public = try ssh_key.loadPublicKey(a, io, other.public);
    const public = try ssh_key.loadPublicKey(a, io, keys.public);

    var e = testEntry();
    try signEntry(a, &e, secret, "2026-09-09T10:00:00Z");
    try testing.expectError(error.KeyMismatch, verifyEntry(a, e, other_public));

    try testing.expectError(error.NoSignature, verifyEntry(a, testEntry(), public));

    var foreign = e;
    foreign.signature.?.algorithm = "rsa";
    try testing.expectError(error.AlgorithmMismatch, verifyEntry(a, foreign, public));

    var garbled = e;
    garbled.signature.?.value = "not base64!!";
    try testing.expectError(error.BadEncoding, verifyEntry(a, garbled, public));
}
