//! Права на файлы для всех целей сборки.
//!
//! У `Io.File.Permissions` на POSIX есть `fromMode`, а на Windows — нет:
//! там нет ни режима, ни бита исполнения, и права выражаются атрибутами.
//! Вызов `.fromMode(0o600)` на Windows не собирается, поэтому все места,
//! где режим важен (хранилище доверия, секреты, плагины в тестах), идут
//! сюда и получают на Windows умолчание.

const std = @import("std");
const Permissions = std.Io.File.Permissions;

pub fn fromMode(comptime mode: u32) Permissions {
    if (comptime @hasDecl(Permissions, "fromMode")) return Permissions.fromMode(mode);
    // Каталоги и файлы на Windows различает сама ОС; здесь только атрибуты.
    return .default_file;
}

/// Режим файла, где он есть. `null` на Windows: там проверять нечего, и
/// тесты с проверкой режима её просто пропускают.
pub fn modeOf(p: Permissions) ?u32 {
    if (comptime !@hasDecl(Permissions, "toMode")) return null;
    return @intCast(p.toMode() & 0o777);
}
