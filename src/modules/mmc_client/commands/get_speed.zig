const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "get_speed");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const velocity = client.get().lines[line_idx].velocity;
    std.log.info(
        "Line {s} speed: {d} {s}",
        .{
            line_name,
            velocity,
            client.standard.speed.unit,
        },
    );
}
