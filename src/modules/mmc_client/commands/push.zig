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

    // If carrier is provided, send the specified carrier to the pushing axis
    // with offset half of carrier length.
    if (carrier_id) |id| check_move: {
        // Continuous push need to move the target carrier to the target axis.
        // Push activation condition is that the hall sensor on the push
        // direction is on or the carrier waited by the pushing axis has
        // movement target that makes the hall sensor on the push direction
        // to be on. Then, the carrier will be pushed to the direction once
        // it is detected by the target axis.
        //
        // Thus, if the target carrier is already on the target axis and the
        // hall sensor of the push direction is already on, the move command is
        // not necessary.
        check_carrier: {
            // This blocks checks whether the move command is necessary or not.
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .info = .{
                        .body = .{
                            .track = .{
                                .line = line.id,
                                .info_axis_state = true,
                                .filter = .{
                                    .axes = .{
                                        .start = axis_id,
                                        .end = axis_id,
                                    },
                                },
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
            // Receive response
            try socket.waitToRead();
            var decoded: api.protobuf.mmc.Response = try .decode(
                &client.reader.interface,
                client.allocator,
            );
            defer decoded.deinit(client.allocator);
            var track = switch (decoded.body orelse return error.InvalidResponse) {
                .info => |info_resp| switch (info_resp.body orelse
                    return error.InvalidResponse) {
                    .track => |track_resp| track_resp,
                    .request_error => |req_err| {
                        return client.error_response.throwInfoError(req_err);
                    },
                    else => return error.InvalidResponse,
                },
                .request_error => |req_err| {
                    return client.error_response.throwMmcError(req_err);
                },
                else => return error.InvalidResponse,
            };
            if (track.line != line.id) return error.InvalidResponse;
            const axis_state = track.axis_state.pop() orelse
                return error.InvalidResponse;
            // If no carrier is detected, continue to move the specified carrier
            // to the pushing axis.
            const carrier = track.carrier_state.pop() orelse
                break :check_carrier;
            if (dir == .DIRECTION_FORWARD and axis_state.hall_alarm_front or
                dir == .DIRECTION_BACKWARD and axis_state.hall_alarm_back)
            {
                // Move command is not necessary in the following condition.
                if (carrier.id == id) break :check_move;
            }
        }
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
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        try client.waitCommandReceived();
    }
}
