//! Адаптеры оболочек: как превратить разрешённое окружение в команды,
//! которые bash, zsh, fish, nushell или PowerShell может применить к себе.
//!
//! Порт `internal/shell/shell.go`. В Go это интерфейс `Adapter` с пятью
//! реализациями; здесь — `union(enum)` и `switch`, потому что набор оболочек
//! закрыт и известен на этапе компиляции.
//!
//! Две оболочки выбиваются из общей схемы, и это не случайность:
//!   - nushell не умеет `eval`, поэтому получает не команды, а JSON, который
//!     hook скармливает `load-env` (см. `supportsDiffRender`);
//!   - bash, zsh и fish дополнительно получают список зависимостей, по
//!     которому hook решает не вызывать envee вовсе (см. `supportsFastPath`).
//!
//! См. docs/adr/0005-shell-hooks.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const escape = @import("escape.zig");

/// Переменная оболочки, которую читают сгенерированные hook'и.
const deps_var = "__envee_deps";

/// Плейсхолдер пути к бинарю внутри hook-шаблонов.
const self_path_placeholder = "{{.SelfPath}}";

/// Разделитель элементов $PATH.
///
/// Go-версия использует ':' на всех платформах, включая Windows, где hook —
/// это PowerShell со своим собственным ';'. Повторяем как есть.
pub const path_list_separator = ':';

pub const Adapter = enum {
    bash,
    zsh,
    fish,
    nu,
    pwsh,

    /// Имя оболочки, как его печатает `envee status` и ждёт `envee eval`.
    pub fn name(a: Adapter) []const u8 {
        return @tagName(a);
    }

    /// Разбор имени оболочки, регистронезависимо. null — не поддерживается.
    ///
    /// "sh" отображается на bash: POSIX-подмножество, которое генерирует
    /// bash-адаптер, исполняется и в sh.
    pub fn detect(s: []const u8) ?Adapter {
        var buf: [16]u8 = undefined;
        if (s.len == 0 or s.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, s);

        const table = .{
            .{ "bash", Adapter.bash },
            .{ "sh", Adapter.bash },
            .{ "zsh", Adapter.zsh },
            .{ "fish", Adapter.fish },
            .{ "nu", Adapter.nu },
            .{ "nushell", Adapter.nu },
            .{ "pwsh", Adapter.pwsh },
            .{ "powershell", Adapter.pwsh },
        };
        inline for (table) |row| {
            if (std.mem.eql(u8, lower, row[0])) return row[1];
        }
        return null;
    }

    /// Код hook'а, который пользователь подключает в конфиге оболочки.
    /// `self_path` — абсолютный путь к бинарю envee.
    pub fn writeInit(a: Adapter, w: *Writer, self_path: []const u8) Writer.Error!void {
        const tpl = switch (a) {
            .bash => @import("hooks/bash.zig").init_template,
            .zsh => @import("hooks/zsh.zig").init_template,
            .fish => @import("hooks/fish.zig").init_template,
            .nu => @import("hooks/nu.zig").init_template,
            .pwsh => @import("hooks/pwsh.zig").init_template,
        };
        var rest = tpl;
        while (std.mem.indexOf(u8, rest, self_path_placeholder)) |i| {
            try w.writeAll(rest[0..i]);
            try w.writeAll(self_path);
            rest = rest[i + self_path_placeholder.len ..];
        }
        try w.writeAll(rest);
    }

    /// Экранирование значения по правилам этой оболочки.
    pub fn writeEscaped(a: Adapter, w: *Writer, value: []const u8) Writer.Error!void {
        return switch (a) {
            .bash, .zsh => escape.writeBashEscaped(w, value),
            .fish => escape.writeFishEscaped(w, value),
            .nu => escape.writeNuEscaped(w, value),
            .pwsh => escape.writePwshEscaped(w, value),
        };
    }

    /// Присваивание переменной. `escaped_value` уже проэкранировано.
    pub fn writeExport(a: Adapter, w: *Writer, key: []const u8, escaped_value: []const u8) Writer.Error!void {
        return switch (a) {
            .bash, .zsh => w.print("export {s}={s};", .{ key, escaped_value }),
            .fish => w.print("set -gx {s} {s}", .{ key, escaped_value }),
            .nu => w.print("$env.{s} = {s}", .{ key, escaped_value }),
            .pwsh => w.print("$env:{s} = {s}", .{ key, escaped_value }),
        };
    }

    /// Удаление переменной.
    pub fn writeUnset(a: Adapter, w: *Writer, key: []const u8) Writer.Error!void {
        return switch (a) {
            .bash => w.print("unset {s} 2>/dev/null || true;", .{key}),
            .zsh => w.print("unset {s} 2>/dev/null;", .{key}),
            .fish => w.print("set -e {s}", .{key}),
            .nu => w.print("hide-env {s}", .{key}),
            .pwsh => w.print("Remove-Item Env:{s} -ErrorAction SilentlyContinue", .{key}),
        };
    }

    /// Добавление каталогов в начало $PATH.
    ///
    /// Пустой список не печатает НИЧЕГО. Присваивание пустого PATH-элемента
    /// POSIX-оболочки трактуют как текущий каталог, то есть это дыра.
    pub fn writeSetPath(a: Adapter, w: *Writer, dirs: []const []const u8) Writer.Error!void {
        if (dirs.len == 0) return;
        switch (a) {
            .bash, .zsh => {
                try w.writeAll("export PATH=");
                for (dirs, 0..) |d, i| {
                    if (i > 0) try w.writeByte(path_list_separator);
                    try escape.writeBashEscaped(w, d);
                }
                try w.writeAll(":\"$PATH\";");
            },
            .fish => {
                try w.writeAll("set -gx PATH ");
                for (dirs, 0..) |d, i| {
                    if (i > 0) try w.writeByte(' ');
                    try escape.writeFishEscaped(w, d);
                }
                try w.writeAll(" $PATH");
            },
            .nu => {
                try w.writeAll("$env.PATH = [");
                for (dirs, 0..) |d, i| {
                    if (i > 0) try w.writeByte(' ');
                    try escape.writeNuEscaped(w, d);
                }
                try w.writeAll(" ...$env.PATH]");
            },
            .pwsh => {
                // Каждый каталог — отдельный литерал в одинарных кавычках,
                // и они СКЛЕИВАЮТСЯ через разделитель. Вложить их в одну
                // строку в двойных кавычках нельзя: сами кавычки попали бы
                // внутрь PATH.
                try w.writeAll("$env:PATH = ");
                for (dirs, 0..) |d, i| {
                    if (i > 0) try w.writeAll(" + ';' + ");
                    try escape.writePwshEscaped(w, d);
                }
                try w.writeAll(" + ';' + $env:PATH");
            },
        }
    }

    /// true, если оболочка не умеет исполнять сгенерированные команды в
    /// области вызывающего и получает весь diff одним куском (см. writeDiff).
    pub fn supportsDiffRender(a: Adapter) bool {
        return a == .nu;
    }

    /// Полезная нагрузка для оболочек без eval: JSON `{"set":{...},"unset":[...]}`.
    ///
    /// `set` печатается с отсортированными ключами (Go получает тот же
    /// порядок от json.Marshal по map), `unset` тоже сортируется — вывод
    /// обязан быть детерминированным. Пустые коллекции обязаны стать `{}` и
    /// `[]`, а не `null`: hook делает `for k in $d.unset` и `$d.set | load-env`,
    /// и null ломает обе конструкции.
    pub fn writeDiff(
        a: Adapter,
        gpa: Allocator,
        w: *Writer,
        set: []const KV,
        unset: []const []const u8,
    ) !void {
        std.debug.assert(a.supportsDiffRender());

        const set_sorted = try gpa.dupe(KV, set);
        defer gpa.free(set_sorted);
        std.mem.sort(KV, set_sorted, {}, KV.lessThan);

        const unset_sorted = try gpa.dupe([]const u8, unset);
        defer gpa.free(unset_sorted);
        std.mem.sort([]const u8, unset_sorted, {}, lessThanString);

        try w.writeAll("{\"set\":{");
        for (set_sorted, 0..) |kv, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(kv.key, .{}, w);
            try w.writeByte(':');
            try std.json.Stringify.value(kv.value, .{}, w);
        }
        try w.writeAll("},\"unset\":[");
        for (unset_sorted, 0..) |k, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(k, .{}, w);
        }
        try w.writeAll("]}\n");
    }

    /// true, если hook этой оболочки умеет пропускать вызов envee, когда
    /// ничего не изменилось.
    pub fn supportsFastPath(a: Adapter) bool {
        return switch (a) {
            .bash, .zsh, .fish => true,
            .nu, .pwsh => false,
        };
    }

    /// Список файлов, от которых зависит результат. Hook сравнивает их с
    /// файлом-меткой средствами самой оболочки и на этом экономит вызов
    /// envee (~4 мс) на каждом приглашении.
    ///
    /// Пути экранируются так же, как значения переменных: это пути на диске,
    /// в них штатно бывают пробелы и кавычки, и они вот-вот будут исполнены
    /// оболочкой как код.
    pub fn writeFastPath(a: Adapter, w: *Writer, deps: []const []const u8) Writer.Error!void {
        switch (a) {
            .bash, .zsh => {
                try w.writeAll(deps_var ++ "=(");
                for (deps, 0..) |d, i| {
                    if (i > 0) try w.writeByte(' ');
                    try escape.writeBashEscaped(w, d);
                }
                try w.writeAll(");\n");
            },
            .fish => {
                if (deps.len == 0) return w.writeAll("set -g " ++ deps_var ++ "\n");
                try w.writeAll("set -g " ++ deps_var ++ " ");
                for (deps, 0..) |d, i| {
                    if (i > 0) try w.writeByte(' ');
                    try escape.writeFishEscaped(w, d);
                }
                try w.writeByte('\n');
            },
            .nu, .pwsh => {},
        }
    }
};

/// Пара ключ-значение для writeDiff.
pub const KV = struct {
    key: []const u8,
    value: []const u8,

    fn lessThan(_: void, a: KV, b: KV) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Собирает вывод writeFn в строку, выделенную в arena.
fn render(
    gpa: Allocator,
    a: Adapter,
    comptime method: []const u8,
    args: anytype,
) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try @call(.auto, @field(Adapter, method), .{ a, &aw.writer } ++ args);
    return aw.toOwnedSlice();
}

test "detect is case-insensitive and covers the aliases" {
    const cases = [_]struct { in: []const u8, want: ?Adapter }{
        .{ .in = "bash", .want = .bash },
        .{ .in = "sh", .want = .bash },
        .{ .in = "zsh", .want = .zsh },
        .{ .in = "fish", .want = .fish },
        .{ .in = "nu", .want = .nu },
        .{ .in = "nushell", .want = .nu },
        .{ .in = "pwsh", .want = .pwsh },
        .{ .in = "powershell", .want = .pwsh },
        .{ .in = "BASH", .want = .bash },
        .{ .in = "Zsh", .want = .zsh },
        .{ .in = "", .want = null },
        .{ .in = "elvish", .want = null },
        .{ .in = "tcsh", .want = null },
        .{ .in = "a-very-long-shell-name-here", .want = null },
    };
    for (cases) |c| try testing.expectEqual(c.want, Adapter.detect(c.in));
}

test "init templates carry the hook and the self path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const self = "/usr/local/bin/envee";

    const bash = try render(a, .bash, "writeInit", .{self});
    try testing.expect(std.mem.indexOf(u8, bash, "_envee_hook") != null);
    try testing.expect(std.mem.indexOf(u8, bash, "PROMPT_COMMAND") != null);
    try testing.expect(std.mem.indexOf(u8, bash, self) != null);
    // Плейсхолдер не должен просочиться в вывод.
    try testing.expect(std.mem.indexOf(u8, bash, self_path_placeholder) == null);

    const zsh = try render(a, .zsh, "writeInit", .{self});
    try testing.expect(std.mem.indexOf(u8, zsh, "add-zsh-hook") != null);

    const fish = try render(a, .fish, "writeInit", .{self});
    try testing.expect(std.mem.indexOf(u8, fish, "function _envee_hook") != null);
    // 'string collect' несущий: без него fish склеивает строки вывода в
    // список и eval соединяет их пробелами.
    try testing.expect(std.mem.indexOf(u8, fish, "string collect") != null);

    // _envee_hook в nushell обязан быть `def --env`, иначе load-env и
    // hide-env внутри него не достают до вызывающего.
    const nu = try render(a, .nu, "writeInit", .{self});
    try testing.expect(std.mem.indexOf(u8, nu, "def --env _envee_hook") != null);
    // Регистрация — строкой, а не замыканием: замыкание проглатывает
    // изменения окружения.
    try testing.expect(std.mem.indexOf(u8, nu, "hooks.env_change.PWD [ \"_envee_hook\" ]") != null);

    // OnIdle в PowerShell исполняет -Action в отдельном runspace, откуда
    // присваивания $env: не доходят до сессии. Hook обязан оборачивать prompt.
    const pwsh = try render(a, .pwsh, "writeInit", .{self});
    try testing.expect(std.mem.indexOf(u8, pwsh, "function global:prompt") != null);
    var it = std.mem.splitScalar(u8, pwsh, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#")) continue; // это объяснение, а не код
        try testing.expect(std.mem.indexOf(u8, trimmed, "Register-EngineEvent") == null);
    }
}

test "export, unset and escape per shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct {
        adapter: Adapter,
        export_out: []const u8,
        unset_out: []const u8,
    }{
        .{ .adapter = .bash, .export_out = "export FOO='bar baz';", .unset_out = "unset FOO 2>/dev/null || true;" },
        .{ .adapter = .zsh, .export_out = "export FOO='bar baz';", .unset_out = "unset FOO 2>/dev/null;" },
        .{ .adapter = .fish, .export_out = "set -gx FOO 'bar baz'", .unset_out = "set -e FOO" },
        .{ .adapter = .nu, .export_out = "$env.FOO = \"bar baz\"", .unset_out = "hide-env FOO" },
        .{ .adapter = .pwsh, .export_out = "$env:FOO = 'bar baz'", .unset_out = "Remove-Item Env:FOO -ErrorAction SilentlyContinue" },
    };
    for (cases) |c| {
        const escaped = try render(a, c.adapter, "writeEscaped", .{"bar baz"});
        const exported = try render(a, c.adapter, "writeExport", .{ "FOO", escaped });
        try testing.expectEqualStrings(c.export_out, exported);
        const unset = try render(a, c.adapter, "writeUnset", .{"FOO"});
        try testing.expectEqualStrings(c.unset_out, unset);
    }
}

test "setPath: empty list emits nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Пустой элемент PATH POSIX-оболочки понимают как текущий каталог,
    // поэтому пустой список обязан не печатать ничего.
    for ([_]Adapter{ .bash, .zsh, .fish, .nu, .pwsh }) |adapter| {
        const got = try render(a, adapter, "writeSetPath", .{&[_][]const u8{}});
        try testing.expectEqualStrings("", got);
    }
}

test "setPath escapes awkward directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dirs = [_][]const u8{ "/a", "/opt/with space/bin", "/opt/with'quote/bin" };
    const cases = [_]struct { adapter: Adapter, want: []const u8 }{
        .{ .adapter = .bash, .want = "export PATH=/a:'/opt/with space/bin':'/opt/with'\\''quote/bin':\"$PATH\";" },
        .{ .adapter = .zsh, .want = "export PATH=/a:'/opt/with space/bin':'/opt/with'\\''quote/bin':\"$PATH\";" },
        .{ .adapter = .fish, .want = "set -gx PATH '/a' '/opt/with space/bin' '/opt/with\\'quote/bin' $PATH" },
        .{ .adapter = .nu, .want = "$env.PATH = [\"/a\" \"/opt/with space/bin\" \"/opt/with'quote/bin\" ...$env.PATH]" },
        .{ .adapter = .pwsh, .want = "$env:PATH = '/a' + ';' + '/opt/with space/bin' + ';' + '/opt/with''quote/bin' + ';' + $env:PATH" },
    };
    for (cases) |c| {
        const got = try render(a, c.adapter, "writeSetPath", .{@as([]const []const u8, &dirs)});
        try testing.expectEqualStrings(c.want, got);
    }
}

test "only nu renders the diff itself" {
    for ([_]Adapter{ .bash, .zsh, .fish, .pwsh }) |adapter| {
        try testing.expect(!adapter.supportsDiffRender());
    }
    try testing.expect(Adapter.nu.supportsDiffRender());
}

test "nu diff is sorted JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: Writer.Allocating = .init(a);
    try Adapter.nu.writeDiff(a, &aw.writer, &.{
        .{ .key = "PATH", .value = "/a:/b" },
        .{ .key = "DATABASE_URL", .value = "postgres://x" },
    }, &.{ "OLD_VAR", "ANOTHER" });

    try testing.expectEqualStrings(
        "{\"set\":{\"DATABASE_URL\":\"postgres://x\",\"PATH\":\"/a:/b\"}," ++
            "\"unset\":[\"ANOTHER\",\"OLD_VAR\"]}\n",
        aw.written(),
    );
}

test "nu diff: empty collections are {} and [], never null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw: Writer.Allocating = .init(a);
    try Adapter.nu.writeDiff(a, &aw.writer, &.{}, &.{});
    // null сломал бы и `for k in $d.unset`, и `$d.set | load-env`.
    try testing.expectEqualStrings("{\"set\":{},\"unset\":[]}\n", aw.written());
}

test "nu diff preserves awkward values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const values = [_]KV{
        .{ .key = "QUOTES", .value = "he said \"hi\" and 'bye'" },
        .{ .key = "NEWLINE", .value = "line1\nline2" },
        .{ .key = "BACKSLASH", .value = "C:\\path\\to" },
        .{ .key = "UTF8", .value = "Привет 🎉" },
        .{ .key = "DOLLAR", .value = "$HOME and `id`" },
    };
    var aw: Writer.Allocating = .init(a);
    try Adapter.nu.writeDiff(a, &aw.writer, &values, &.{});

    // Разбираем обратно и сверяем каждое значение.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
    defer parsed.deinit();
    const set = parsed.value.object.get("set").?.object;
    for (values) |kv| {
        try testing.expectEqualStrings(kv.value, set.get(kv.key).?.string);
    }
}

test "fast path is offered only where the hook implements it" {
    for ([_]Adapter{ .bash, .zsh, .fish }) |adapter| {
        try testing.expect(adapter.supportsFastPath());
    }
    for ([_]Adapter{ .nu, .pwsh }) |adapter| {
        try testing.expect(!adapter.supportsFastPath());
    }
}

test "fast path list is escaped, and an empty list still resets the variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const deps = [_][]const u8{ "/a dir/it's here.toml", "/plain/path.toml" };
    const cases = [_]struct { adapter: Adapter, want: []const u8, empty: []const u8 }{
        .{
            .adapter = .bash,
            .want = "__envee_deps=('/a dir/it'\\''s here.toml' /plain/path.toml);\n",
            .empty = "__envee_deps=();\n",
        },
        .{
            .adapter = .zsh,
            .want = "__envee_deps=('/a dir/it'\\''s here.toml' /plain/path.toml);\n",
            .empty = "__envee_deps=();\n",
        },
        .{
            .adapter = .fish,
            .want = "set -g __envee_deps '/a dir/it\\'s here.toml' '/plain/path.toml'\n",
            .empty = "set -g __envee_deps\n",
        },
    };
    for (cases) |c| {
        const got = try render(a, c.adapter, "writeFastPath", .{@as([]const []const u8, &deps)});
        try testing.expectEqualStrings(c.want, got);
        const empty = try render(a, c.adapter, "writeFastPath", .{&[_][]const u8{}});
        try testing.expectEqualStrings(c.empty, empty);
    }

    // Оболочки без fast path не печатают ничего.
    for ([_]Adapter{ .nu, .pwsh }) |adapter| {
        const got = try render(a, adapter, "writeFastPath", .{@as([]const []const u8, &deps)});
        try testing.expectEqualStrings("", got);
    }
}
