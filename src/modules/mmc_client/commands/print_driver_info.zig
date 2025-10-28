const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_driver_info");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: client.Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_driver_state = true,
                .info_driver_errors = true,
                .filter = filter.toProtobuf(),
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
    const driver_state = track.driver_state;
    const driver_errors = track.driver_errors;
    if (driver_state.items.len != driver_errors.items.len)
        return error.InvalidResponse;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (driver_state.items, driver_errors.items) |info, err| {
        try client.api.response.info.track.driver.state.print(info, writer);
        try client.api.response.info.track.driver.err.print(err, writer);
    }
}
