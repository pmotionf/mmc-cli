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
    const axis_id: ?struct { start: u32, end: u32 } = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b .{ .start = axis, .end = axis },
            .driver => |driver| {
                const start = (driver - 1) * 3 + 1;
                const end = (driver - 1) * 3 + 3;
                break :b .{ .start = start, .end = end };
            },
            .carrier => {
                {
                    try client.removeIgnoredMessage(socket);
                    try socket.waitToWrite(&command.checkCommandInterrupt);
                    var writer = socket.writer(&client.writer_buf);
                    try client.api.request.info.track.encode(
                        client.allocator,
                        &writer.interface,
                        .{
                            .line = line.id,
                            .info_carrier_state = true,
                            .filter = _filter.toProtobuf(),
                        },
                    );
                    try writer.interface.flush();
                }
                try socket.waitToRead(&command.checkCommandInterrupt);
                var reader = socket.reader(&client.reader_buf);
                var track = try client.api.response.info.track.decode(
                    client.allocator,
                    &reader.interface,
                );
                defer track.deinit(client.allocator);
                if (track.line != line.id) return error.InvalidResponse;
                var carriers = track.carrier_state;
                if (carriers.items.len > 1) return error.InvalidResponse;
                const carrier = carriers.pop() orelse return error.CarrierNotFound;
                break :b .{ .start = carrier.axis_main, .end = carrier.axis_main };
            },
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.deinitialize.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axes = if (axis_id) |id|
                    .{ .start = id.start, .end = id.end }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
