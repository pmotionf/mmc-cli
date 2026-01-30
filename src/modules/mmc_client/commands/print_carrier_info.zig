const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_carrier_info");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: ?client.Filter = if (params[1].len > 0)
        try .parse(params[1])
    else
        null;
    const pb_filter = if (filter) |*f| f.toProtobuf() else null;
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
                        .filter = pb_filter,
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
    if (carriers.items.len == 0) return error.CarrierNotFound;
    var writer_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
    const writer = &stdout.interface;
    for (carriers.items) |carrier| {
        _ = try client.nestedWrite("Carrier state", carrier, 0, writer);
        try writer.flush();
    }
}
