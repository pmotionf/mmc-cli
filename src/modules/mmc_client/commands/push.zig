const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn forward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "push_forward");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    try impl(params, .DIRECTION_FORWARD);
}

pub fn backward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "push_backward");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    try impl(params, .DIRECTION_BACKWARD);
}

fn impl(
    params: [][]const u8,
    comptime dir: api.protobuf.mmc.command.Request.Direction,
) !void {
    if (dir == .DIRECTION_UNSPECIFIED) @compileError("InvalidDirection");
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const axis_id: u32 = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id: ?u32 = if (params[2].len > 0) try std.fmt.parseInt(u10, b: {
        const input = params[2];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0) else null;

    // Push command request
    {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .command = .{
                    .body = .{
                        .push = .{
                            .line = line.id,
                            .velocity = line.velocity.value,
                            .velocity_mode = if (line.velocity.low)
                                .VELOCITY_MODE_LOW
                            else
                                .VELOCITY_MODE_NORMAL,
                            .acceleration = line.acceleration,
                            .direction = dir,
                            .axis = axis_id,
                            .carrier = carrier_id,
                        },
                    },
                },
            },
        };
        std.log.debug("request: {}", .{request.body.?.command.body.?.push});
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
        // Send push message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        try client.waitCommandReceived();
    }
    // If carrier is provided, send the specified carrier to the pushing axis
    // with offset half of carrier length.
    if (carrier_id) |id| {
        const location =
            line.length.axis * @as(f32, @floatFromInt(axis_id - 1)) +
            switch (dir) {
                .DIRECTION_BACKWARD => -line.length.carrier / 2.0,
                .DIRECTION_FORWARD => line.length.carrier / 2.0,
                else => unreachable,
            };
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .command = .{
                    .body = .{
                        .move = .{
                            .line = line.id,
                            .carrier = id,
                            .velocity = line.velocity.value,
                            .velocity_mode = if (line.velocity.low)
                                .VELOCITY_MODE_LOW
                            else
                                .VELOCITY_MODE_NORMAL,
                            .acceleration = line.acceleration,
                            .target = .{ .location = location },
                            .disable_cas = true,
                            .control = .CONTROL_POSITION,
                        },
                    },
                },
            },
        };
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        try client.waitCommandReceived();
    }
}
