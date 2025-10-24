const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn forward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?u32 = if (params[2].len > 0)
        try std.fmt.parseInt(u32, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.move.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .target = .{
                        .location = line.length.axis * @as(
                            f32,
                            @floatFromInt(axis - 1),
                        ) + 0.15,
                        // 0.15: offset for continuous push (m)
                    },
                    .disable_cas = true,
                    .control = .CONTROL_POSITION,
                },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.push.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .direction = .DIRECTION_FORWARD,
                    .axis = axis,
                },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        return;
    }
    // Get the axis information
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        var ids: [1]u32 = .{carrier_id};
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                },
            },
        );
        try writer.interface.flush();
    }
    const carrier = carrier: {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        var carrier_state = track.carrier_state;
        break :carrier carrier_state.pop() orelse return error.CarrierNotFound;
    };
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.push.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier.id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_FORWARD,
                .axis = carrier.axis_main,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn backward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?u32 = if (params[2].len > 0)
        try std.fmt.parseInt(u32, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.move.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
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
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        {
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.push.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .direction = .DIRECTION_BACKWARD,
                    .axis = axis,
                },
            );
            try writer.interface.flush();
        }
        try client.waitCommandReceived();
        return;
    }
    // Get the axis information
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        var ids: [1]u32 = .{carrier_id};
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                },
            },
        );
        try writer.interface.flush();
    }
    const carrier = carrier: {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        var carrier_state = track.carrier_state;
        break :carrier carrier_state.pop() orelse return error.CarrierNotFound;
    };
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.push.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier.id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .axis = carrier.axis_main,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
