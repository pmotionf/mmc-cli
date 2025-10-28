const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "axis_carrier");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const save_var: []const u8 = params[2];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;
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
                .filter = .{
                    .axes = .{
                        .start = axis_id,
                        .end = axis_id,
                    },
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
    std.log.info("Carrier {d} on axis {d}.\n", .{ carrier.id, axis_id });
    if (save_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            save_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
        );
    }
}
