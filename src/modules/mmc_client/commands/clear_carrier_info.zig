const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "clear_carrier_info");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.stream orelse return error.ServerNotConnected;
    var writer_buf: [4096]u8 = undefined;
    var net_writer = net.writer(io, &writer_buf);
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
                    .deinitialize = .{
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
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    try client.waitCommandReceived(io);
}
