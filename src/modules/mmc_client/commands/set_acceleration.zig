const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "set_acceleration");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 24500)
        return error.InvalidAcceleration;

    const line_idx = try client.matchLine(line_name);
    client.get().lines[line_idx].acceleration = carrier_acceleration;

    std.log.info("Set acceleration to {d} {s}.", .{
        client.get().lines[line_idx].acceleration,
        client.standard.acceleration.unit,
    });
}
