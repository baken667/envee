//! Чтение ключей ed25519 в форматах OpenSSH.
//!
//! Заменяет `golang.org/x/crypto/ssh` из Go-версии. Нужны ровно две вещи:
//! приватный ключ из `~/.ssh/id_ed25519` и публичный из `id_ed25519.pub`
//! (формат authorized_keys). Разбор обоих умещается в сотню строк, и тянуть
//! ради него библиотеку незачем.
//!
//! Принимается только ed25519. RSA-ключ молча принять нельзя: формат записи
//! закрепляет алгоритм, и подпись другим ключом никто не сможет проверить.
//! Ключ с парольной фразой тоже отвергается: envee не спрашивает пароли,
//! и честнее сказать об этом, чем зависнуть на вводе.
//!
//! Формат приватного ключа (PROTOCOL.key из OpenSSH): после base64 идут
//! магическая строка `openssh-key-v1\0`, затем поля с префиксом длины:
//! шифр, KDF, параметры KDF, число ключей, публичный блок, приватный блок.
//! Внутри приватного блока — два контрольных числа, тип, публичный ключ,
//! 64 байта приватного (seed || pub), комментарий и набивка.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Файл не начинается с ожидаемого заголовка.
    NotOpenSsh,
    /// Ключ зашифрован парольной фразой.
    PassphraseProtected,
    /// Тип ключа не ed25519.
    NotEd25519,
    /// Структура файла нарушена.
    Malformed,
} || Allocator.Error || std.Io.Dir.ReadFileAllocError;

/// 64 байта приватного ключа в кодировке OpenSSH: seed || public.
/// Ровно то, что `std.crypto.sign.Ed25519.SecretKey.fromBytes` ожидает.
pub const SecretBytes = [64]u8;
pub const PublicBytes = [32]u8;

const key_type = "ssh-ed25519";
const magic = "openssh-key-v1\x00";

pub fn loadPrivateKey(arena: Allocator, io: std.Io, path: []const u8) Error!SecretBytes {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    return parsePrivateKey(arena, data);
}

pub fn loadPublicKey(arena: Allocator, io: std.Io, path: []const u8) Error!PublicBytes {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    return parsePublicKey(arena, data);
}

pub fn parsePrivateKey(arena: Allocator, pem: []const u8) Error!SecretBytes {
    const body = try pemBody(arena, pem, "OPENSSH PRIVATE KEY");
    var r: Reader = .{ .buf = body };

    const head = r.bytes(magic.len) catch return error.NotOpenSsh;
    if (!std.mem.eql(u8, head, magic)) return error.NotOpenSsh;

    const cipher = try r.string();
    const kdf = try r.string();
    _ = try r.string(); // параметры KDF
    if (!std.mem.eql(u8, cipher, "none") or !std.mem.eql(u8, kdf, "none")) {
        return error.PassphraseProtected;
    }

    const nkeys = try r.word();
    if (nkeys != 1) return error.Malformed;

    // Публичный блок: тип и 32 байта. Тип проверяем здесь же, до приватной
    // части, — так RSA отвергается ещё до чтения секрета.
    const pub_blob = try r.string();
    var pr: Reader = .{ .buf = pub_blob };
    const pub_type = try pr.string();
    if (!std.mem.eql(u8, pub_type, key_type)) return error.NotEd25519;
    const pub_from_blob = try pr.string();
    if (pub_from_blob.len != 32) return error.Malformed;

    const private_blob = try r.string();
    var sr: Reader = .{ .buf = private_blob };
    const check1 = try sr.word();
    const check2 = try sr.word();
    // Совпадение контрольных чисел — единственный признак того, что блок
    // расшифрован верно. Без шифра они обязаны совпадать всегда.
    if (check1 != check2) return error.Malformed;

    const inner_type = try sr.string();
    if (!std.mem.eql(u8, inner_type, key_type)) return error.NotEd25519;
    const pub_inner = try sr.string();
    const secret = try sr.string();
    if (pub_inner.len != 32 or secret.len != 64) return error.Malformed;
    // Вторая половина секрета — это тот же публичный ключ; расхождение
    // значит, что файл собран из частей разных ключей.
    if (!std.mem.eql(u8, secret[32..], pub_inner)) return error.Malformed;
    if (!std.mem.eql(u8, pub_inner, pub_from_blob)) return error.Malformed;

    var out: SecretBytes = undefined;
    @memcpy(&out, secret);
    return out;
}

/// Строка формата authorized_keys: `ssh-ed25519 <base64> [комментарий]`.
pub fn parsePublicKey(arena: Allocator, text: []const u8) Error!PublicBytes {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const typ = fields.next() orelse return error.Malformed;
    if (!std.mem.eql(u8, typ, key_type)) return error.NotEd25519;
    const encoded = fields.next() orelse return error.Malformed;

    const blob = try decodeBase64(arena, encoded);
    var r: Reader = .{ .buf = blob };
    const blob_type = try r.string();
    if (!std.mem.eql(u8, blob_type, key_type)) return error.NotEd25519;
    const key = try r.string();
    if (key.len != 32) return error.Malformed;

    var out: PublicBytes = undefined;
    @memcpy(&out, key);
    return out;
}

/// Вырезает и декодирует тело PEM между строками BEGIN и END.
fn pemBody(arena: Allocator, pem: []const u8, label: []const u8) Error![]u8 {
    const begin = try std.fmt.allocPrint(arena, "-----BEGIN {s}-----", .{label});
    const end = try std.fmt.allocPrint(arena, "-----END {s}-----", .{label});

    const start = std.mem.indexOf(u8, pem, begin) orelse return error.NotOpenSsh;
    const stop = std.mem.indexOf(u8, pem, end) orelse return error.NotOpenSsh;
    if (stop <= start) return error.NotOpenSsh;
    const inner = pem[start + begin.len .. stop];

    // Переводы строк внутри base64 надо выбросить до декодирования.
    var compact: std.ArrayList(u8) = .empty;
    for (inner) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
        try compact.append(arena, c);
    }
    return decodeBase64(arena, compact.items);
}

fn decodeBase64(arena: Allocator, encoded: []const u8) Error![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.Malformed;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, encoded) catch return error.Malformed;
    return out;
}

/// Чтение полей SSH-формата: big-endian длина, затем байты.
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.buf.len) return error.Malformed;
        defer r.pos += n;
        return r.buf[r.pos .. r.pos + n];
    }

    fn word(r: *Reader) Error!u32 {
        const b = try r.bytes(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }

    fn string(r: *Reader) Error![]const u8 {
        const n = try r.word();
        return r.bytes(n);
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Настоящая пара ключей от ssh-keygen: формат проверяется на том, что есть
/// у пользователей, а не на том, что породили мы сами.
pub const KeyPairFiles = struct {
    dir: []const u8,
    private: []const u8,
    public: []const u8,

    pub fn generate(arena: Allocator, io: std.Io, key_type_flag: []const u8) !?KeyPairFiles {
        const cwd_path = try std.process.currentPathAlloc(io, arena);
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
        const dir = try std.fs.path.join(arena, &.{ cwd_path, ".zig-cache", "tmp", &name });
        try std.Io.Dir.cwd().createDirPath(io, dir);

        const private = try std.fs.path.join(arena, &.{ dir, "id_key" });
        const result = std.process.run(arena, io, .{
            .argv = &.{ "ssh-keygen", "-q", "-t", key_type_flag, "-N", "", "-C", "envee-test", "-f", private },
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (result.term != .exited or result.term.exited != 0) return error.KeygenFailed;
        return .{
            .dir = dir,
            .private = private,
            .public = try std.fmt.allocPrint(arena, "{s}.pub", .{private}),
        };
    }

    pub fn destroy(k: KeyPairFiles, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, k.dir) catch {};
    }
};

test "a real ssh-keygen ed25519 pair parses, and the halves agree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const keys = (try KeyPairFiles.generate(a, io, "ed25519")) orelse return error.SkipZigTest;
    defer keys.destroy(io);

    const secret = try loadPrivateKey(a, io, keys.private);
    const public = try loadPublicKey(a, io, keys.public);

    // Вторая половина приватного ключа — это публичный.
    try testing.expectEqualSlices(u8, &public, secret[32..]);

    // И криптография с ним согласна: подпись проверяется.
    const Ed25519 = std.crypto.sign.Ed25519;
    const kp = try Ed25519.KeyPair.fromSecretKey(try Ed25519.SecretKey.fromBytes(secret));
    const sig = try kp.sign("hello", null);
    try sig.verify("hello", try Ed25519.PublicKey.fromBytes(public));
}

test "an RSA key is refused, not misread" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const keys = (try KeyPairFiles.generate(a, io, "rsa")) orelse return error.SkipZigTest;
    defer keys.destroy(io);

    try testing.expectError(error.NotEd25519, loadPrivateKey(a, io, keys.private));
    try testing.expectError(error.NotEd25519, loadPublicKey(a, io, keys.public));
}

// envee не спрашивает пароли, и зависнуть на вводе было бы хуже отказа.
test "a passphrase-protected key is refused with the reason" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    const cwd_path = try std.process.currentPathAlloc(io, a);
    var random_bytes: [12]u8 = undefined;
    io.random(&random_bytes);
    var name: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);
    const dir = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &name });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const private = try std.fs.path.join(a, &.{ dir, "id_locked" });
    const result = std.process.run(a, io, .{
        .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "hunter2", "-f", private },
    }) catch return error.SkipZigTest;
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;

    try testing.expectError(error.PassphraseProtected, loadPrivateKey(a, io, private));
}

test "a known public key line decodes to the expected bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Ключ из фикстуры testdata/go_signed: сгенерирован ssh-keygen, подпись
    // им сделана Go-версией.
    const line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM5bvHu6NWySqnjeOBUA5Am2MNUGzajMbmmvbG6kuT5L envee-test\n";
    const pub_key = try parsePublicKey(a, line);
    try testing.expectEqualStrings(
        "ce5bbc7bba356c92aa78de381500e409b630d506cda8cc6e69af6c6ea4b93e4b",
        &std.fmt.bytesToHex(pub_key, .lower),
    );
    // Комментарий необязателен.
    _ = try parsePublicKey(a, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM5bvHu6NWySqnjeOBUA5Am2MNUGzajMbmmvbG6kuT5L");
}

test "garbage is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.NotOpenSsh, parsePrivateKey(a, "not a key"));
    try testing.expectError(error.NotOpenSsh, parsePrivateKey(a, "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"));
    try testing.expectError(error.Malformed, parsePublicKey(a, ""));
    try testing.expectError(error.NotEd25519, parsePublicKey(a, "ssh-rsa AAAA comment"));
    try testing.expectError(error.Malformed, parsePublicKey(a, "ssh-ed25519 not-base64!!"));
    // Правильный заголовок, но обрезанное тело.
    try testing.expectError(error.Malformed, parsePrivateKey(a, "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----\n"));
}
