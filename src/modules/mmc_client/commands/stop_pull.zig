const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "stop_pull");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const axis_id: ?struct { start: u32, end: u32 } = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b .{ .start = axis, .end = axis },
            .driver => |driver| break :b .{
                .start = driver * 3 - 2,
                .end = driver * 3,
            },
            .carrier => return error.InvalidParameter,
        }
    } else null;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .stop_pull = .{
                        .line = line.id,
                        .axes = if (axis_id) |id|
                            .{ .start = id.start, .end = id.end }
                        else
                            null,
                    },
                },
            },
        },
    };
    try client.sendRequest(client.allocator, net, request);
    try client.waitCommandCompleted(client.allocator, net);
}
