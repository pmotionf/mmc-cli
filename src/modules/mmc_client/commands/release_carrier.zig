//! This file contains client for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "release_carrier");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const driver_id: ?u32 = if (params[1].len == 0)
        null
    else
        try std.fmt.parseInt(u32, buf: {
            const input = params[1];
            var suffix: ?usize = null;
            for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
                // Only valid suffix for axis_id is either 'd' or "driver".
                if (c != 'd') return error.InvalidCharacter;
                suffix = i;
                break;
            };
            if (suffix) |ignore_idx| {
                if (ignore_idx == 0) return error.InvalidCharacter;
                break :buf input[0..ignore_idx];
            } else break :buf input;
        }, 0);
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .release = .{
                        .line = line.id,
                        .drivers = if (driver_id) |id|
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
