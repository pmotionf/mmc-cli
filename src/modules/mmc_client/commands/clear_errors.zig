const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.clear_errors.encode(
            client.allocator,
            &writer.interface,
            .{
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
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
