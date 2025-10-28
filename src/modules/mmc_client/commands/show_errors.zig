const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "show_errors");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        try client.api.request.info.track.encode(
            client.allocator,
            &client.writer.interface,
            .{
                .line = line.id,
                .info_axis_errors = true,
                .info_driver_errors = true,
                .filter = if (filter) |*_filter|
                    _filter.toProtobuf()
                else
                    null,
            },
        );
        try client.writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &client.reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const axis_errors = track.axis_errors;
    const driver_errors = track.driver_errors;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (axis_errors.items) |err| {
        try client.api.response.info.track.axis.err.printActive(
            err,
            writer,
        );
    }
    for (driver_errors.items) |err| {
        try client.api.response.info.track.driver.err.printActive(
            err,
            writer,
        );
    }
}
