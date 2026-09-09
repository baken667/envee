//! Поддельный плагин для тестов `plugin.zig`.
//!
//! Порт `internal/plugin/testdata/fakeplugin`: поведение целиком задаётся
//! переменной `FAKE_PLUGIN_MODE`, так что один бинарь изображает все
//! режимы отказа настоящего плагина. Собирается в build.zig как артефакт
//! для тестов и устанавливается под несколькими именами `envee-plugin-*`.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const mode = init.environ_map.get("FAKE_PLUGIN_MODE") orelse "";

    var out_buf: [4096]u8 = undefined;
    var stdout_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout_file.interface;
    var err_buf: [1024]u8 = undefined;
    var stderr_file: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err_out = &stderr_file.interface;

    if (argv.len < 2) {
        try err_out.writeAll("usage: fakeplugin <metadata|resolve>\n");
        try err_out.flush();
        std.process.exit(2);
    }

    if (std.mem.eql(u8, mode, "exit_nonzero")) {
        try err_out.writeAll("fakeplugin: deliberate failure\n");
        try err_out.flush();
        std.process.exit(1);
    }
    if (std.mem.eql(u8, mode, "garbage")) {
        try out.writeAll("this is not json at all\n");
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "hang")) {
        const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };
        try timeout.sleep(io);
        return;
    }

    const sub = argv[1];
    if (std.mem.eql(u8, sub, "metadata")) {
        try out.writeAll(
            \\{"name":"fake","version":"9.9.9","api_version":1,"description":"fake plugin for tests","capabilities":["secret"]}
            \\
        );
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, sub, "resolve")) {
        var in_buf: [4096]u8 = undefined;
        var stdin_file: Io.File.Reader = .init(.stdin(), io, &in_buf);
        const body = try stdin_file.interface.allocRemaining(arena, .unlimited);

        var request_id: []const u8 = "";
        var ref: []const u8 = "";
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})) |v| {
            if (v == .object) {
                if (v.object.get("request_id")) |id| if (id == .string) {
                    request_id = id.string;
                };
                if (v.object.get("spec")) |spec| if (spec == .object) {
                    if (spec.object.get("ref")) |r| if (r == .string) {
                        ref = r.string;
                    };
                };
            }
        } else |_| {}

        try out.writeAll("{\"api_version\":1,\"request_id\":");
        try std.json.Stringify.value(request_id, .{}, out);
        if (std.mem.eql(u8, mode, "error_response")) {
            try out.writeAll(",\"status\":\"error\",\"error\":{\"code\":\"E_NOT_FOUND\",\"message\":");
            try std.json.Stringify.value(try std.fmt.allocPrint(arena, "no such secret: {s}", .{ref}), .{}, out);
            try out.writeAll(",\"recoverable\":false}}\n");
        } else if (std.mem.eql(u8, mode, "status_not_ok")) {
            try out.writeAll(",\"status\":\"degraded\"}\n");
        } else if (std.mem.eql(u8, mode, "null_value")) {
            try out.writeAll(",\"status\":\"ok\"}\n");
        } else if (std.mem.eql(u8, mode, "int_value")) {
            try out.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"int\",\"value\":42}}\n");
        } else if (std.mem.eql(u8, mode, "bool_value")) {
            try out.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"bool\",\"value\":true}}\n");
        } else if (std.mem.eql(u8, mode, "json_value")) {
            try out.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"json\",\"value\":{\"a\":1}}}\n");
        } else {
            try out.writeAll(",\"status\":\"ok\",\"value\":{\"type\":\"string\",\"value\":");
            try std.json.Stringify.value(try std.fmt.allocPrint(arena, "resolved:{s}", .{ref}), .{}, out);
            try out.writeAll("}}\n");
        }
        try out.flush();
        return;
    }

    try err_out.print("unknown subcommand {s}\n", .{sub});
    try err_out.flush();
    std.process.exit(2);
}
