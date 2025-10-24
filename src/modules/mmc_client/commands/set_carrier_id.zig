const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier = try std.fmt.parseInt(u32, params[1], 0);
    const new_carrier = try std.fmt.parseInt(u32, params[2], 0);
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.set_carrier_id.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier,
                .new_carrier = new_carrier,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
