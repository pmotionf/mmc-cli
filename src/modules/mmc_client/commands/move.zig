const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn posAxis(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_pos_axis");
    defer tracy_zone.end();
    const axis_id = try std.fmt.parseInt(u32, params[2], 0);
    try impl(params, .CONTROL_POSITION, .{ .axis = axis_id });
}

pub fn posLocation(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_pos_location");
    defer tracy_zone.end();
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    try impl(params, .CONTROL_POSITION, .{ .location = location });
}

pub fn posDistance(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_pos_distance");
    defer tracy_zone.end();
    const distance = try std.fmt.parseFloat(f32, params[2]);
    try impl(params, .CONTROL_POSITION, .{ .distance = distance });
}

pub fn spdAxis(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_spd_axis");
    defer tracy_zone.end();
    const axis_id = try std.fmt.parseInt(u32, params[2], 0);
    try impl(params, .CONTROL_VELOCITY, .{ .axis = axis_id });
}

pub fn spdLocation(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_spd_location");
    defer tracy_zone.end();
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    try impl(params, .CONTROL_VELOCITY, .{ .location = location });
}

pub fn spdDistance(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_spd_distance");
    defer tracy_zone.end();
    const distance = try std.fmt.parseFloat(f32, params[2]);
    try impl(params, .CONTROL_VELOCITY, .{ .distance = distance });
}

fn impl(
    params: [][]const u8,
    control: api.protobuf.mmc.Control,
    target: api.protobuf.mmc.command.Request.Move.target_union,
) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier_id: u10 = try std.fmt.parseInt(u10, b: {
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
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
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
                        .target = target,
                        .disable_cas = disable_cas,
                        .control = control,
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
