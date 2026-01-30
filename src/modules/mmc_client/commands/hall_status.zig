const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "hall_status");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: ?client.Filter = null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var lines: std.ArrayList(u32) = .{};
    defer lines.deinit(client.allocator);
    try lines.append(client.allocator, @as(u32, @intCast(line.id)));
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .lines = lines,
                        .info_axis_state = true,
                        .filter = if (filter) |*_filter|
                            _filter.toProtobuf()
                        else
                            null,
                    },
                },
            },
        },
    };
    try client.sendRequest(client.allocator, net, request);
    var decoded = try client.getResponse(client.allocator, net);
    defer decoded.deinit(client.allocator);
    const track = switch (decoded.body orelse return error.InvalidResponse) {
        .info => |info_resp| switch (info_resp.body orelse
            return error.InvalidResponse) {
            .track => |track_resp| track_resp,
            .request_error => |req_err| {
                return client.error_response.throwInfoError(req_err);
            },
            else => return error.InvalidResponse,
        },
        .request_error => |req_err| {
            return client.error_response.throwMmcError(req_err);
        },
        else => return error.InvalidResponse,
    };
    const wanted_line: u32 = @as(u32, @intCast(line.id));
    const track_line = blk: {
        for (track.lines.items) |*t| {
            if (t.id == wanted_line) break :blk t;
        }
        return error.InvalidResponse;
    };

    if (filter) |_filter| {
        switch (_filter) {
            .axis => if (track_line.axis_state.items.len != 1)
                return error.InvalidResponse,
            else => {},
        }
    } else {
        if (track_line.axis_state.items.len != line.axes)
            return error.InvalidResponse;
    }
    for (track_line.axis_state.items) |axis| {
        std.log.info(
            "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
            .{
                axis.id,
                if (axis.hall_alarm_back) "ON" else "OFF",
                if (axis.hall_alarm_front) "ON" else "OFF",
            },
        );
    }
}
