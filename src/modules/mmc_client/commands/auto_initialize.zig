//! This file contains callbacks for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");
const CommandRequest = @FieldType(
    api.protobuf.mmc.Request.body_union,
    "command",
);

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "auto_initialize");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    var init_lines: std.ArrayList(CommandRequest.AutoInitialize.Line) = .empty;
    defer init_lines.deinit(gpa);
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try client.matchLine(line_name);
            const _line = client.lines[line_idx];
            const line: CommandRequest.AutoInitialize.Line = .{
                .line = _line.id,
            };
            try init_lines.append(gpa, line);
        }
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .auto_initialize = .{
                        .lines = init_lines,
                    },
                },
            },
        },
    };
    try client.sendRequest(io, gpa, net, request);
    try client.waitCommandCompleted(io, gpa, net);
}

test {
    std.testing.refAllDecls(@This());
}
