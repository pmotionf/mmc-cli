const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "get_speed");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const velocity = client.lines[line_idx].velocity;
    std.log.info(
        "Line {s} speed: {d} mm/s",
        .{
            line_name,
            @as(f32, @floatFromInt(velocity.value)) /
                @as(f32, if (velocity.low) 10 else 0.01),
        },
    );
}
