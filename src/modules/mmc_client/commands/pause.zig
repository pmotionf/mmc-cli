const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids: [1]u32 = .{0};
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        ids[0] = @intCast(line_idx + 1);
    }
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pause.encode(
            client.allocator,
            &writer.interface,
            .{
                .lines = .fromOwnedSlice(if (ids[0] > 0) &ids else &.{}),
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
