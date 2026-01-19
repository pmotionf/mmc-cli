const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

const Standard = client.Standard;
const standard: Standard = .{};

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "set_speed");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];
    const carrier_speed: f32 = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed < 0 or carrier_speed > 6) return error.InvalidSpeed;
    // from 0.1 to 100 mm/s => low, 100 to 6000.0 mm/s=> normal mode.
    const low = carrier_speed < 0.1;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].velocity = .{
        .value = carrier_speed *
            @as(f32, if (low) 10.0 else 0.01),
        .low = low,
    };

    std.log.info(
        "Set speed to {d} {s}",
        .{
            @as(f32, client.lines[line_idx].velocity.value) /
                @as(f32, if (low) 10 else 0.01),
            standard.speed.unit,
        },
    );
}
