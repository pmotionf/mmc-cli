//! This file contains client for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "release_carrier");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .release = .{
                        .line = line.id,
                        .target = if (filter) |f| b: switch (f) {
                            .axis => |axis| break :b .{
                                .axes = .{ .start = axis, .end = axis },
                            },
                            .driver => |driver| break :b .{
                                .drivers = .{ .start = driver, .end = driver },
                            },
                            .carrier => |carrier| break :b .{
                                .carrier = carrier[0],
                            },
                        } else null,
                    },
                },
            },
        },
    };
    try client.sendRequest(client.allocator, net, request);
    try client.waitCommandCompleted(client.allocator, net);
}
