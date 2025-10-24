const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn posAxis(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(
        u32,
        params[2],
        0,
    );
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn posLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn posDistance(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn spdAxis(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(u32, params[2], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn spdLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}

pub fn spdDistance(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
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
                .velocity = client.lines[line_idx].velocity.value,
                .velocity_mode = if (client.lines[line_idx].velocity.low)
                    .VELOCITY_MODE_LOW
                else
                    .VELOCITY_MODE_NORMAL,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
