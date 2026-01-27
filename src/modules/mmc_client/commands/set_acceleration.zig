const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "set_acceleration");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]) / 1000;
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 24.5)
        return error.InvalidAcceleration;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].acceleration = @intFromFloat(carrier_acceleration * 10.0);

    std.log.info("Set acceleration to {d} {s}.", .{
        @as(f32, @floatFromInt(client.lines[line_idx].acceleration)) * 100,
        client.standard.acceleration.unit,
    });
}
