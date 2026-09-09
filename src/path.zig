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

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn isSep(c: u8) bool {
    return c == '/';
}

/// Лексическая нормализация пути, эквивалент Go filepath.Clean.
pub fn clean(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    if (path.len == 0) return gpa.dupe(u8, ".");

    const rooted = isSep(path[0]);
    const n = path.len;
    var out = try gpa.alloc(u8, path.len + 1);
    errdefer gpa.free(out);
    var w: usize = 0;
    var r: usize = 0;
    var dotdot: usize = 0;

    if (rooted) {
        out[w] = '/';
        w += 1;
        r = 1;
        dotdot = 1;
    }

    while (r < n) {
        if (isSep(path[r])) {
            r += 1;
        } else if (path[r] == '.' and (r + 1 == n or isSep(path[r + 1]))) {
            // Элемент "." ничего не значит.
            r += 1;
        } else if (path[r] == '.' and r + 1 < n and path[r + 1] == '.' and
            (r + 2 == n or isSep(path[r + 2])))
        {
            r += 2;
            if (w > dotdot) {
                // Съедаем предыдущий элемент.
                w -= 1;
                while (w > dotdot and !isSep(out[w])) w -= 1;
            } else if (!rooted) {
                // ".." в начале относительного пути сократить не с чем.
                if (w > 0) {
                    out[w] = '/';
                    w += 1;
                }
                out[w] = '.';
                out[w + 1] = '.';
                w += 2;
                dotdot = w;
            }
        } else {
            if ((rooted and w != 1) or (!rooted and w != 0)) {
                out[w] = '/';
                w += 1;
            }
            while (r < n and !isSep(path[r])) : (r += 1) {
                out[w] = path[r];
                w += 1;
            }
        }
    }

    if (w == 0) {
        gpa.free(out);
        return gpa.dupe(u8, ".");
    }
    return gpa.realloc(out, w);
}

/// Эквивалент Go filepath.Dir: всё, кроме последнего элемента, нормализовано.
pub fn dirname(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var i: isize = @as(isize, @intCast(path.len)) - 1;
    while (i >= 0 and !isSep(path[@intCast(i)])) i -= 1;
    const cut = path[0..@intCast(i + 1)];
    return clean(gpa, cut);
}

/// Эквивалент Go filepath.Base: последний элемент пути.
pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var p = path;
    while (p.len > 0 and isSep(p[p.len - 1])) p = p[0 .. p.len - 1];
    var i: isize = @as(isize, @intCast(p.len)) - 1;
    while (i >= 0 and !isSep(p[@intCast(i)])) i -= 1;
    if (i >= 0) p = p[@intCast(i + 1)..];
    if (p.len == 0) return "/";
    return p;
}

/// Эквивалент Go filepath.Abs.
pub fn absPath(gpa: Allocator, io: std.Io, path: []const u8) AbsError![]u8 {
    if (path.len > 0 and isSep(path[0])) return clean(gpa, path);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path });
    defer gpa.free(joined);
    return clean(gpa, joined);
}

pub const AbsError = Allocator.Error || std.process.CurrentPathAllocError;

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
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return clean(gpa, buf[0..n]);
}
