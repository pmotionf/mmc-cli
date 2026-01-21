const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, _: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "reset_system");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
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
            // Clear all buffer in reader and writer for safety.
            _ = net_reader.interface.discardRemaining() catch {};
            _ = net_writer.interface.consumeAll();
            // Send message
            try request.encode(&net_writer.interface, client.allocator);
            try net_writer.interface.flush();
            try client.waitCommandReceived(io);
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
            // Clear all buffer in reader and writer for safety.
            _ = net_reader.interface.discardRemaining() catch {};
            _ = net_writer.interface.consumeAll();
            // Send message
            try request.encode(&net_writer.interface, client.allocator);
            try net_writer.interface.flush();
            try client.waitCommandReceived(io);
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
            // Clear all buffer in reader and writer for safety.
            _ = net_reader.interface.discardRemaining() catch {};
            _ = net_writer.interface.consumeAll();
            // Send message
            try request.encode(&net_writer.interface, client.allocator);
            try net_writer.interface.flush();
            try client.waitCommandReceived(io);
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
            // Clear all buffer in reader and writer for safety.
            _ = net_reader.interface.discardRemaining() catch {};
            _ = net_writer.interface.consumeAll();
            // Send message
            try request.encode(&net_writer.interface, client.allocator);
            try net_writer.interface.flush();
            try client.waitCommandReceived(io);
        }
    }
}
