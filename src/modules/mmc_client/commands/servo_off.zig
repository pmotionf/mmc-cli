//! This file contains client for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "servo_off");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const axis_id: ?u32 = if (params[1].len > 0)
        try std.fmt.parseUnsigned(u32, params[1], 0)
    else
        null;

    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .servo_off = .{
                        .line = line.id,
                        .axes = if (axis_id) |id|
                            .{ .start = id, .end = id }
                        else
                            null,
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
