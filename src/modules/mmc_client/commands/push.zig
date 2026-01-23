const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const net = client.stream orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const axis_id: u32 = try std.fmt.parseInt(u32, buf: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for axis_id is either 'a' or "axis".
            if (c != 'a') return error.InvalidCharacter;
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :buf input[0..ignore_idx];
        } else break :buf input;
    }, 0);
    const dir: api.protobuf.mmc.command.Request.Direction =
        if (std.mem.eql(u8, "forward", params[2]))
            .DIRECTION_FORWARD
        else if (std.mem.eql(u8, "backward", params[2]))
            .DIRECTION_BACKWARD
        else
            return error.InvalidDirection;
    const carrier_id: ?u32 = if (params[3].len > 0) try std.fmt.parseInt(u10, b: {
        const input = params[3];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for carrier id is either 'c' or "carrier".
            if (c != 'c') return error.InvalidCharacter;
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
            try client.sendRequest(io, client.allocator, net, request);
            var response = try client.readResponse(io, client.allocator, net);
            defer response.deinit(client.allocator);
            var track = switch (response.body orelse return error.InvalidResponse) {
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
                .DIRECTION_BACKWARD => -line.length.axis / 2.0,
                .DIRECTION_FORWARD => line.length.axis / 2.0,
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
                            .disable_cas = false,
                            .control = .CONTROL_POSITION,
                        },
                    },
                },
            },
        };
        try client.sendRequest(io, client.allocator, net, request);
        try client.waitCommandCompleted(io);
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
        try client.sendRequest(io, client.allocator, net, request);
        try client.waitCommandCompleted(io);
    }
}
