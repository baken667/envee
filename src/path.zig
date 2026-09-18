//! Операции над путями с семантикой Go `path/filepath`.
//!
//! Вынесено отдельно, потому что нужно и шаблонам (фильтры dirname,
//! basename, abspath), и оркестратору директив (склейка `_.path`).
//!
//! Зачем свои функции, когда есть `std.fs.path`: она отвечает на те же
//! вопросы иначе. `std.fs.path.dirname` возвращает null там, где Go даёт
//! "." или "/", а `join` не нормализует путь, из-за чего `./bin`
//! превращается в `<корень>/./bin` вместо `<корень>/bin`. Обе разницы
//! видны пользователю: первая — в значениях переменных, вторая — прямо в
//! $PATH.
//!
//! Как и Go, разделитель зависит от ОС: на Windows это `\`, `/` тоже
//! принимается, а буква диска (`C:`) сохраняется. Раньше здесь всегда был
//! `/`, и путь, собранный этим модулем, не совпадал побайтно с путём от
//! `std.fs.path` — а по пути хранится запрет в trust store, так что
//! `envee deny` на Windows не действовал. Реализация параметризована ОС,
//! чтобы Windows-семантику можно было проверить на любой машине.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const native = For(builtin.os.tag == .windows);

pub const sep = native.sep;
pub const isSep = native.isSep;
pub const clean = native.clean;
pub const dirname = native.dirname;
pub const basename = native.basename;
pub const absPath = native.absPath;
pub const join = native.join;

pub const AbsError = Allocator.Error || std.process.CurrentPathAllocError;

pub fn For(comptime windows: bool) type {
    return struct {
        const Self = @This();

        pub const sep: u8 = if (windows) '\\' else '/';

        pub fn isSep(c: u8) bool {
            return c == '/' or (windows and c == '\\');
        }

        /// Длина буквы диска в начале пути (`C:`), 0 — её нет.
        // ponytail: UNC-пути (\\server\share) не разбираются как том; их
        // префикс нормализуется как обычный корень.
        fn volumeLen(path: []const u8) usize {
            if (windows and path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) return 2;
            return 0;
        }

        /// Лексическая нормализация пути, эквивалент Go filepath.Clean.
        pub fn clean(gpa: Allocator, full: []const u8) Allocator.Error![]u8 {
            const vol_len = volumeLen(full);
            const vol = full[0..vol_len];
            const path = full[vol_len..];
            if (path.len == 0) return std.fmt.allocPrint(gpa, "{s}.", .{vol});

            const rooted = Self.isSep(path[0]);
            const n = path.len;
            var out = try gpa.alloc(u8, vol_len + path.len + 1);
            errdefer gpa.free(out);
            @memcpy(out[0..vol_len], vol);
            var w: usize = vol_len;
            var r: usize = 0;
            var dotdot: usize = vol_len;
            const base = vol_len;

            if (rooted) {
                out[w] = Self.sep;
                w += 1;
                r = 1;
                dotdot = w;
            }

            while (r < n) {
                if (Self.isSep(path[r])) {
                    r += 1;
                } else if (path[r] == '.' and (r + 1 == n or Self.isSep(path[r + 1]))) {
                    // Элемент "." ничего не значит.
                    r += 1;
                } else if (path[r] == '.' and r + 1 < n and path[r + 1] == '.' and
                    (r + 2 == n or Self.isSep(path[r + 2])))
                {
                    r += 2;
                    if (w > dotdot) {
                        // Съедаем предыдущий элемент.
                        w -= 1;
                        while (w > dotdot and out[w] != Self.sep) w -= 1;
                    } else if (!rooted) {
                        // ".." в начале относительного пути сократить не с чем.
                        if (w > base) {
                            out[w] = Self.sep;
                            w += 1;
                        }
                        out[w] = '.';
                        out[w + 1] = '.';
                        w += 2;
                        dotdot = w;
                    }
                } else {
                    if ((rooted and w != base + 1) or (!rooted and w != base)) {
                        out[w] = Self.sep;
                        w += 1;
                    }
                    while (r < n and !Self.isSep(path[r])) : (r += 1) {
                        out[w] = path[r];
                        w += 1;
                    }
                }
            }

            if (w == base) {
                out[w] = '.';
                w += 1;
            }
            return gpa.realloc(out, w);
        }

        /// Эквивалент Go filepath.Dir: всё, кроме последнего элемента, нормализовано.
        pub fn dirname(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
            const vol_len = volumeLen(path);
            var i: usize = path.len;
            while (i > vol_len and !Self.isSep(path[i - 1])) i -= 1;
            return Self.clean(gpa, path[0..i]);
        }

        /// Эквивалент Go filepath.Base: последний элемент пути.
        pub fn basename(full: []const u8) []const u8 {
            if (full.len == 0) return ".";
            var p = full[volumeLen(full)..];
            while (p.len > 0 and Self.isSep(p[p.len - 1])) p = p[0 .. p.len - 1];
            var i: usize = p.len;
            while (i > 0 and !Self.isSep(p[i - 1])) i -= 1;
            p = p[i..];
            if (p.len == 0) return if (windows) "\\" else "/";
            return p;
        }

        fn isAbs(path: []const u8) bool {
            const v = volumeLen(path);
            // На Windows `C:foo` и `\foo` — не абсолютные: первый зависит
            // от текущего каталога диска, второй — от текущего диска.
            if (windows) return v > 0 and path.len > v and Self.isSep(path[v]);
            return path.len > 0 and path[0] == '/';
        }

        /// Эквивалент Go filepath.Abs.
        pub fn absPath(gpa: Allocator, io: std.Io, path: []const u8) AbsError![]u8 {
            if (isAbs(path)) return Self.clean(gpa, path);
            const cwd = try std.process.currentPathAlloc(io, gpa);
            defer gpa.free(cwd);
            return Self.join(gpa, &.{ cwd, path });
        }

        /// Склейка с нормализацией — эквивалент Go filepath.Join.
        ///
        /// Именно нормализация отличает её от `std.fs.path.join`: без неё
        /// `join(root, "./bin")` даёт `root/./bin`, и этот мусор уезжает в $PATH.
        pub fn join(gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
            var total: usize = 0;
            for (parts) |p| total += p.len + 1;
            var buf = try gpa.alloc(u8, total);
            defer gpa.free(buf);

            var n: usize = 0;
            for (parts) |p| {
                if (p.len == 0) continue;
                if (n > 0) {
                    buf[n] = Self.sep;
                    n += 1;
                }
                @memcpy(buf[n..][0..p.len], p);
                n += p.len;
            }
            return Self.clean(gpa, buf[0..n]);
        }
    };
}

// ---- тесты -------------------------------------------------------------------

const testing = std.testing;

fn expectClean(comptime P: type, in: []const u8, want: []const u8) !void {
    const got = try P.clean(testing.allocator, in);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "posix: clean, join, dirname and basename match Go filepath" {
    const P = For(false);
    try expectClean(P, "", ".");
    try expectClean(P, "/", "/");
    try expectClean(P, "a/./b/../c//", "a/c");
    try expectClean(P, "/../x", "/x");
    try expectClean(P, "../../x", "../../x");
    try expectClean(P, "a\\b", "a\\b");

    const j = try P.join(testing.allocator, &.{ "/root", "./bin" });
    defer testing.allocator.free(j);
    try testing.expectEqualStrings("/root/bin", j);
    const d = try P.dirname(testing.allocator, "/a/b/c");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/a/b", d);
    const d2 = try P.dirname(testing.allocator, "file");
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings(".", d2);
    try testing.expectEqualStrings("c", P.basename("/a/b/c/"));
    try testing.expectEqualStrings("/", P.basename("///"));
}

test "windows: backslash separators, both accepted, drive letter kept" {
    const P = For(true);
    try expectClean(P, "C:/Users/a/./b/../envee.toml", "C:\\Users\\a\\envee.toml");
    try expectClean(P, "C:\\", "C:\\");
    try expectClean(P, "C:", "C:.");
    try expectClean(P, "C:\\..\\x", "C:\\x");
    try expectClean(P, "a/b\\..\\c", "a\\c");

    // Главное: склейка даёт тот же путь, что std.fs.path.join на Windows,
    // иначе ключ запрета в trust store расходится с путём из resolver.
    const j = try P.join(testing.allocator, &.{ "D:\\a\\proj", "envee.toml" });
    defer testing.allocator.free(j);
    try testing.expectEqualStrings("D:\\a\\proj\\envee.toml", j);
    const d = try P.dirname(testing.allocator, "D:\\a\\proj\\envee.toml");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("D:\\a\\proj", d);
    const d2 = try P.dirname(testing.allocator, "D:\\envee.toml");
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings("D:\\", d2);
    try testing.expectEqualStrings("envee.toml", P.basename("D:\\a/envee.toml"));
    try testing.expectEqualStrings("\\", P.basename("D:\\"));
    try testing.expect(P.isAbs("D:\\x") and !P.isAbs("D:x") and !P.isAbs("\\x"));
}
