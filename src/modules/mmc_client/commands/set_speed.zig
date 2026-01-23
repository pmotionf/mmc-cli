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
    if (carrier_speed < 0 or carrier_speed > 6000) return error.InvalidSpeed;
    // from 0.1 to 6000.0 mm/s

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].velocity = carrier_speed;

    std.log.info(
        "Set speed to {d} {s}",
        .{
            client.lines[line_idx].velocity,
            standard.speed.unit,
        },
    );
}
