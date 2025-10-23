const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
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
                .info_carrier_state = true,
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
    const carriers = track.carrier_state;
    if (carriers.items.len == 0) return error.CarrierNotFound;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (carriers.items) |carrier| {
        try client.api.response.info.track.carrier.print(carrier, writer);
    }
}
