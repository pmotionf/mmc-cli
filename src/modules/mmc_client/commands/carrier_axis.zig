const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(client.allocator);
        try ids.append(client.allocator, carrier_id);
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = ids },
                },
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
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    std.log.info(
        "Carrier {d} axis: {}",
        .{ carrier.id, carrier.axis_main },
    );
    if (carrier.axis_auxiliary) |aux|
        std.log.info(
            "Carrier {d} axis: {}",
            .{ carrier.id, aux },
        );
}
