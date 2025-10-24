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
    const driver_id: ?u32 = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b axis / 3,
            .driver => |driver| break :b driver,
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
                break :b carrier.axis_main / 3;
            },
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.clear_errors.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .drivers = if (driver_id) |id|
                    .{ .start = id, .end = id }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
