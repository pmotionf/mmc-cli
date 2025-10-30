const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn forward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "push_forward");
    defer tracy_zone.end();
    try impl(params, .DIRECTION_FORWARD);
}

pub fn backward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "push_backward");
    defer tracy_zone.end();
    try impl(params, .DIRECTION_BACKWARD);
}

fn impl(
    params: [][]const u8,
    dir: api.protobuf.mmc.command.Request.Direction,
) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier_id = try std.fmt.parseInt(u10, b: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0);

    const axis_id: ?u32 = if (params[2].len > 0)
        try std.fmt.parseInt(u32, params[2], 0)
    else
        null;
    if (axis_id) |axis| {
        // Send move command to the provided axis.
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .move = .{
                                .line = line.id,
                                .carrier = carrier_id,
                                .velocity = line.velocity.value,
                                .velocity_mode = if (line.velocity.low)
                                    .VELOCITY_MODE_LOW
                                else
                                    .VELOCITY_MODE_NORMAL,
                                .acceleration = line.acceleration,
                                .target = .{
                                    .location = line.length.axis * @as(
                                        f32,
                                        @floatFromInt(axis - 1),
                                    ) - 0.15,
                                    // 0.15: offset for continuous push
                                },
                                .disable_cas = true,
                                .control = .CONTROL_POSITION,
                            },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
        // Send push command to the provided axis
        {
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .command = .{
                        .body = .{
                            .push = .{
                                .line = line.id,
                                .carrier = carrier_id,
                                .velocity = line.velocity.value,
                                .velocity_mode = if (line.velocity.low)
                                    .VELOCITY_MODE_LOW
                                else
                                    .VELOCITY_MODE_NORMAL,
                                .acceleration = line.acceleration,
                                .direction = dir,
                                .axis = axis,
                            },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            try client.waitCommandReceived();
        }
        return;
    }
    // Request carrier information
    const carrier = carrier: {
        var ids = [1]u32{carrier_id};
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .info = .{
                    .body = .{
                        .track = .{
                            .line = line.id,
                            .info_carrier_state = true,
                            .filter = .{
                                .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                            },
                        },
                    },
                },
            },
        };
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        // Receive response
        try socket.waitToRead(&command.checkCommandInterrupt);
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
        if (track.line != line.id) return error.InvalidResponse;
        var carrier_state = track.carrier_state;
        break :carrier carrier_state.pop() orelse return error.CarrierNotFound;
    };
    // Push command request
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
                        .axis = carrier.axis_main,
                    },
                },
            },
        },
    };
    try client.removeIgnoredMessage(socket);
    try socket.waitToWrite(&command.checkCommandInterrupt);
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    try client.waitCommandReceived();
}
