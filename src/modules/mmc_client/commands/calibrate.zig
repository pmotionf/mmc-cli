const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "calibrate");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.get().sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.get().lines[line_idx];
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .calibrate = .{ .line = line.id },
                },
            },
        },
    };
    try client.sendRequest(client.get().allocator, net, request);
    try client.waitCommandCompleted(client.get().allocator, net);
}
