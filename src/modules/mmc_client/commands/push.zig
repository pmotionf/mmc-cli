const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    if (client.sock == null) return error.ServerNotConnected;
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
            var lines: std.ArrayList(u32) = .{};
            defer lines.deinit(client.allocator);
            try lines.append(client.allocator, @as(u32, @intCast(line.id)));
            // This blocks checks whether the move command is necessary or not.
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .info = .{
                        .body = .{
                            .track = .{
                                .lines = lines,
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
            // Clear all buffer in reader and writer for safety.
            _ = client.reader.interface.discardRemaining() catch {};
            _ = client.writer.interface.consumeAll();
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            // Receive response
            while (true) {
                try command.checkCommandInterrupt();
                const byte = client.reader.interface.peekByte() catch |e| {
                    switch (e) {
                        std.Io.Reader.Error.EndOfStream => continue,
                        std.Io.Reader.Error.ReadFailed => {
                            return switch (client.reader.error_state orelse error.Unexpected) {
                                else => |err| err,
                            };
                        },
                    }
                };
                if (byte > 0) break;
            }
            var decoded: api.protobuf.mmc.Response = try .decode(
                &client.reader.interface,
                client.allocator,
            );
            defer decoded.deinit(client.allocator);
            const track = switch (decoded.body orelse return error.InvalidResponse) {
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
            const wanted_line: u32 = @as(u32, @intCast(line.id));
            const track_line = blk: {
                for (track.lines.items) |*t| {
                    if (t.line == wanted_line) break :blk t;
                }
                return error.InvalidResponse;
            };
            const axis_state = track_line.axis_state.pop() orelse
                return error.InvalidResponse;
            // If no carrier is detected, continue to move the specified carrier
            // to the pushing axis.
            const carrier = track_line.carrier_state.pop() orelse
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
                            .velocity = line.velocity,
                            .acceleration = line.acceleration,
                            .target = .{ .location = location },
                            .disable_cas = false,
                            .control = .CONTROL_POSITION,
                        },
                    },
                },
            },
        };
        // Clear all buffer in reader and writer for safety.
        _ = client.reader.interface.discardRemaining() catch {};
        _ = client.writer.interface.consumeAll();
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
                            .velocity = line.velocity,
                            .acceleration = line.acceleration,
                            .direction = dir,
                            .axis = axis_id,
                            .carrier = carrier_id,
                        },
                    },
                },
            },
        };
        // Clear all buffer in reader and writer for safety.
        _ = client.reader.interface.discardRemaining() catch {};
        _ = client.writer.interface.consumeAll();
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        try client.waitCommandReceived();
    }
}
