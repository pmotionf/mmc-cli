const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "get_acceleration");
    defer tracy_zone.end();
    const line_name: []const u8 = params[0];

    const line_idx = try client.matchLine(line_name);
    std.log.info(
        "Line {s} acceleration: {d} {s}",
        .{
            line_name,
            client.get().lines[line_idx].acceleration,
            client.standard.acceleration.unit,
        },
    );
}
