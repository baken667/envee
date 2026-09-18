//! Точка входа `envee-plugin-op`. Логика — в `plugins/op.zig`,
//! процессный каркас — в `plugins/protocol.zig`.

const std = @import("std");
const protocol = @import("plugins/protocol.zig");
const op = @import("plugins/op.zig");

pub fn main(init: std.process.Init) !void {
    return protocol.main(init, op.run);
}
