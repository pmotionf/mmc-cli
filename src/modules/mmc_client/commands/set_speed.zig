const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 6.0) return error.InvalidSpeed;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].velocity = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(client.lines[line_idx].velocity)) / 10.0,
    });
}
