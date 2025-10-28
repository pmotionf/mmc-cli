const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_axis_info");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: client.Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        try client.api.request.info.track.encode(
            client.allocator,
            &client.writer.interface,
            .{
                .line = line.id,
                .info_axis_errors = true,
                .info_axis_state = true,
                .filter = filter.toProtobuf(),
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
    const axis_state = track.axis_state;
    const axis_errors = track.axis_errors;
    if (axis_state.items.len != axis_errors.items.len)
        return error.InvalidResponse;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (axis_state.items, axis_errors.items) |info, err| {
        try client.api.response.info.track.axis.state.print(info, writer);
        try client.api.response.info.track.axis.err.print(err, writer);
    }
}
