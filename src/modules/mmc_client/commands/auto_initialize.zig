//! This file contains callbacks for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var init_lines: std.ArrayList(
        client.api.api.protobuf.mmc.command.Request.AutoInitialize.Line,
    ) = .empty;
    defer init_lines.deinit(client.allocator);
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try client.matchLine(line_name);
            const _line = client.lines[line_idx];
            const line: client.api.api.protobuf.mmc.command.Request.AutoInitialize.Line = .{
                .line = _line.id,
            };
            try init_lines.append(client.allocator, line);
        }
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.auto_initialize.encode(
            client.allocator,
            &writer.interface,
            .{ .lines = init_lines },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
