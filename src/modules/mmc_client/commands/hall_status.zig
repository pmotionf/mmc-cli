const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "hall_status");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: ?client.Filter = null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    if (filter) |*_filter| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
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
        for (track.axis_state.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm_back) "ON" else "OFF",
                    if (axis.hall_alarm_front) "ON" else "OFF",
                },
            );
        }
    } else {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = null,
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
        if (track.line != line.id and
            track.axis_state.items.len != line.axes)
            return error.InvalidResponse;
        // Starts printing hall status
        for (track.axis_state.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm_back) "ON" else "OFF",
                    if (axis.hall_alarm_front) "ON" else "OFF",
                },
            );
        }
    }
}
