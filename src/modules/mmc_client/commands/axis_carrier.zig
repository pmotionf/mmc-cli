const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "axis_carrier");
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
    const save_var: []const u8 = params[2];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var line_array: [1]u32 = .{line.id};
    const lines: std.ArrayList(u32) = .fromOwnedSlice(&line_array);
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .lines = lines,
                        .info_carrier_state = true,
                        .filter = .{
                            .axes = .{ .start = axis_id, .end = axis_id },
                        },
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
    const carriers = track_line.carrier_state;
    if (carriers.items.len > 1) return error.InvalidResponse;
    for (carriers.items) |carrier| {
        std.log.info("Carrier {d} on Axis {d}.\n", .{ carrier.id, axis_id });
        if (save_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                save_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
            );
        }
    }
}
