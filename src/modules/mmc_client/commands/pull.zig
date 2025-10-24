const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn forward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pull.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axis = axis_id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .low
                else
                    .normal,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_FORWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn backward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pull.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axis = axis_id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .low
                else
                    .normal,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
