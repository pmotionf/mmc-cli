const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_axis_info");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: client.Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_axis_errors = true,
                        .info_axis_state = true,
                        .filter = filter.toProtobuf(),
                    },
                },
            },
        },
    };
    // Clear all buffer in reader and writer for safety.
    _ = client.reader.interface.discardRemaining() catch {};
    _ = client.writer.interface.consumeAll();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    // Receive response
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
    const axis_state = track.axis_state;
    const axis_errors = track.axis_errors;
    if (axis_state.items.len != axis_errors.items.len)
        return error.InvalidResponse;
    var writer_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
    const writer = &stdout.interface;
    for (axis_state.items, axis_errors.items) |info, err| {
        _ = try client.nestedWrite(
            "Axis state",
            info,
            0,
            writer,
        );
        _ = try client.nestedWrite(
            "Axis error",
            err,
            0,
            writer,
        );
        try writer.flush();
    }
}
