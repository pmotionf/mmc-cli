const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "reset_system");
    defer tracy_zone.end();
    errdefer client.Log.stop.store(true, .monotonic);
    const socket = client.sock orelse return error.ServerNotConnected;
    for (client.lines) |line| {
        // Send deinitialize command
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .deinitialize = .{ .line = line.id },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite();
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
        // Send clear errors command
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .clear_errors = .{ .line = line.id },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite();
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
        // Send stop push command
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .stop_push = .{ .line = line.id },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite();
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
        // Send stop pull command
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .stop_pull = .{ .line = line.id },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite();
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
    }
}
