const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(_: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "clear_carrier_info");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    if (client.sock == null) return error.ServerNotConnected;
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
    // Clear all buffer in reader and writer for safety.
    _ = client.reader.interface.discardRemaining() catch {};
    _ = client.writer.interface.consumeAll();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    try client.waitCommandReceived();
}
