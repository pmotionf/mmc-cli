const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "get_acceleration");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];

    const line_idx = try client.matchLine(line_name);
    std.log.info(
        "Line {s} acceleration: {d} m/s^2",
        .{
            line_name,
            @as(f32, @floatFromInt(client.lines[line_idx].acceleration)) / 10.0,
        },
    );
}
