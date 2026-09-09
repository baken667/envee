//! Точка входа `envee-plugin-infisical`. Логика — в `plugins/infisical.zig`,
//! процессный каркас — в `plugins/protocol.zig`.

const std = @import("std");
const protocol = @import("plugins/protocol.zig");
const infisical = @import("plugins/infisical.zig");

pub fn main(init: std.process.Init) !void {
    return protocol.main(init, infisical.run);
}
