const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "stop");
    defer tracy_zone.end();
    const net = client.stream orelse return error.ServerNotConnected;
    var ids: [1]u32 = .{0};
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        ids[0] = @intCast(line_idx + 1);
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .stop = .{
                        .lines = .fromOwnedSlice(if (ids[0] > 0) &ids else &.{}),
                    },
                },
            },
        },
    };
    try client.sendRequest(io, client.allocator, net, request);
    try client.waitCommandCompleted(io);
}
