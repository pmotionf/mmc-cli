const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn forward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "pull_forward");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    try impl(params, .DIRECTION_FORWARD);
}

pub fn backward(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "pull_backward");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    try impl(params, .DIRECTION_BACKWARD);
}

fn impl(
    params: [][]const u8,
    dir: api.protobuf.mmc.command.Request.Direction,
) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, b: {
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
    }, 0);
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
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .pull = .{
                        .line = line.id,
                        .axis = axis_id,
                        .carrier = carrier_id,
                        .velocity = line.velocity.value,
                        .velocity_mode = if (line.velocity.low)
                            .VELOCITY_MODE_LOW
                        else
                            .VELOCITY_MODE_NORMAL,
                        .acceleration = line.acceleration,
                        .direction = dir,
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
