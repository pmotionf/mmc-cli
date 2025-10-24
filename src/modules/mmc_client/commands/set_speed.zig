const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed < 0 or carrier_speed > 6) return error.InvalidSpeed;
    // from 0.0001 to 0.1 => low, 0.1 to 6.0 => normal mode.
    const low = carrier_speed < 0.1;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].velocity = .{
        .value = @intFromFloat(carrier_speed *
            @as(f32, if (low) 10_000.0 else 10.0)),
        .low = low,
    };

    std.log.info(
        "Set speed to {d} m/s.",
        .{
            @as(f32, @floatFromInt(client.lines[line_idx].velocity.value)) /
                @as(f32, if (low) 10_000 else 10.0),
        },
    );
}
