const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "isolate");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, buf: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for axis_id is either 'a' or "axis".
            if (c != 'a') return error.InvalidCharacter;
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :buf input[0..ignore_idx];
        } else break :buf input;
    }, 0);

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];

    const dir: api.protobuf.mmc.command.Request.Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .DIRECTION_FORWARD;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .DIRECTION_BACKWARD;
        } else {
            return error.InvalidDirection;
        }
    };

    const carrier_id = try std.fmt.parseUnsigned(u32, b: {
        const input = params[3];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for carrier id is either 'c' or "carrier".
            if (c != 'c') return error.InvalidCharacter;
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0);
    const link_axis: ?api.protobuf.mmc.command.Request.Direction = link: {
        if (params[4].len > 0) {
            if (std.ascii.eqlIgnoreCase("next", params[4]) or
                std.ascii.eqlIgnoreCase("right", params[4]))
            {
                break :link .DIRECTION_FORWARD;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .DIRECTION_BACKWARD;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link null;
    };
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .initialize = .{
                        .line = line.id,
                        .axis = axis_id,
                        .carrier = carrier_id,
                        .link_axis = link_axis,
                        .direction = dir,
                    },
                },
            },
        },
    };
    try client.sendRequest(client.allocator, net, request);
    try client.waitCommandCompleted(client.allocator, net);
}
