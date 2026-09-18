//! Точка входа `envee-plugin-sops`. Логика — в `plugins/sops.zig`,
//! процессный каркас — в `plugins/protocol.zig`.

const std = @import("std");
const protocol = @import("plugins/protocol.zig");
const sops = @import("plugins/sops.zig");

pub fn main(init: std.process.Init) !void {
    return protocol.main(init, sops.run);
}
