//! This file contains callbacks for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "auto_initialize");
    defer tracy_zone.end();
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
        try client.api.request.command.auto_initialize.encode(
            client.allocator,
            &client.writer.interface,
            .{ .lines = init_lines },
        );
        try client.writer.interface.flush();
    }
    try client.waitCommandReceived();
}
