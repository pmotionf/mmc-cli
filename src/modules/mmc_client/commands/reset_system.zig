const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "reset_system");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    for (client.lines) |line| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            try client.api.request.command.deinitialize.encode(
                client.allocator,
                &client.writer.interface,
                .{ .line = line.id },
            );
            try client.writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            try client.api.request.command.clear_errors.encode(
                client.allocator,
                &client.writer.interface,
                .{ .line = line.id },
            );
            try client.writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            try client.api.request.command.stop_push.encode(
                client.allocator,
                &client.writer.interface,
                .{ .line = line.id },
            );
            try client.writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            try client.api.request.command.stop_pull.encode(
                client.allocator,
                &client.writer.interface,
                .{ .line = line.id },
            );
            try client.writer.interface.flush();
        }
        try client.waitCommandReceived();
    }
}
