const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "axis_carrier");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const save_var: []const u8 = params[2];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_carrier_state = true,
                        .filter = .{
                            .axes = .{ .start = axis_id, .end = axis_id },
                        },
                    },
                },
            },
        },
    };
    try client.removeIgnoredMessage(socket);
    try socket.waitToWrite();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    // Receive message
    try socket.waitToRead();
    var decoded: api.protobuf.mmc.Response = try .decode(
        &client.reader.interface,
        client.allocator,
    );
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
    if (track.line != line.id) return error.InvalidResponse;
    const carriers = track.carrier_state;
    if (carriers.items.len > 1) return error.InvalidResponse;
    for (carriers.items) |carrier| {
        std.log.info("Carrier {d} on axis {d}.\n", .{ carrier.id, axis_id });
        if (save_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                save_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
            );
        }
    }
}
