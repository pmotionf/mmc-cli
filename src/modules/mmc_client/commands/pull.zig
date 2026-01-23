const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const net = client.stream orelse return error.ServerNotConnected;
    var writer_buf: [4096]u8 = undefined;
    var net_writer = net.writer(io, &writer_buf);
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, buf: {
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
    const carrier_id = try std.fmt.parseInt(u10, b: {
        const input = params[2];
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
    }, 0);
    const dir: api.protobuf.mmc.command.Request.Direction =
        if (std.mem.eql(u8, "forward", params[3]))
            .DIRECTION_FORWARD
        else if (std.mem.eql(u8, "backward", params[3]))
            .DIRECTION_BACKWARD
        else
            return error.InvalidDirection;
    const destination: ?f32 = if (params[4].len > 0)
        try std.fmt.parseFloat(f32, params[4]) / 1000.0
    else
        null;

    const no_servo: bool = if (destination) |loc|
        std.math.isNan(loc)
    else
        false;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[5].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("on", params[5]))
        false
    else if (std.ascii.eqlIgnoreCase("off", params[5]))
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
                        .velocity = if (no_servo) 0 else line.velocity.value,
                        .velocity_mode = if (line.velocity.low)
                            .VELOCITY_MODE_LOW
                        else
                            .VELOCITY_MODE_NORMAL,
                        .acceleration = if (no_servo)
                            0
                        else
                            line.acceleration,
                        .direction = dir,
                        .transition = blk: {
                            if (destination) |loc| break :blk .{
                                .control = if (no_servo)
                                    .CONTROL_UNSPECIFIED
                                else
                                    .CONTROL_POSITION,
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
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    try client.waitCommandReceived(io);
}
