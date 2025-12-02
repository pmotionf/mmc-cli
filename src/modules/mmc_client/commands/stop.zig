const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "stop");
    defer tracy_zone.end();
    if (client.sock == null) return error.ServerNotConnected;
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
    // Clear all buffer in reader and writer for safety.
    _ = client.reader.interface.discardRemaining() catch {};
    _ = client.writer.interface.consumeAll();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    try client.waitCommandReceived();
}
