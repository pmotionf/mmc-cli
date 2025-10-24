const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(_: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    for (client.lines) |line| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.deinitialize.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.clear_errors.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.stop_push.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.stop_pull.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
    }
}
