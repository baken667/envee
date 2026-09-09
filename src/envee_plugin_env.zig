//! Точка входа `envee-plugin-env`. Вся логика — в `plugins/env.zig`, общий
//! процессный каркас — в `plugins/protocol.zig`.
//!
//! Файл лежит в корне `src/`, а не в `src/plugins/`: корень модуля задаёт
//! каталог, за пределы которого `@import` не выходит, а плагинам нужны
//! `secret_store.zig` и `trust/store.zig`.

const std = @import("std");
const protocol = @import("plugins/protocol.zig");
const env_plugin = @import("plugins/env.zig");

pub fn main(init: std.process.Init) !void {
    return protocol.main(init, env_plugin.run);
}
