//! This file contains callbacks for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "auto_initialize");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
    var init_lines: std.ArrayList(
        api.protobuf.mmc.command.Request.AutoInitialize.Line,
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
            const line: api.protobuf.mmc.command.Request.AutoInitialize.Line = .{
                .line = _line.id,
            };
            try init_lines.append(client.allocator, line);
        }
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .auto_initialize = .{
                        .lines = init_lines,
                    },
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
