const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "assert_location");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    if (client.sock == null) return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var ids = [1]u32{try std.fmt.parseInt(u32, b: {
        const input = params[1];
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
    }, 0)};
    const expected_location: f32 =
        try std.fmt.parseFloat(f32, params[2]) / 1000.0;
    // Default location threshold value is 1 mm
    const location_thr = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3]) / 1000.0
    else
        0.001;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var lines: std.ArrayList(u32) = .{};
    defer lines.deinit(client.allocator);
    try lines.append(client.allocator, @as(u32, @intCast(line.id)));
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .lines = lines,
                        .info_carrier_state = true,
                        .filter = .{
                            .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                        },
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
    while (true) {
        try command.checkCommandInterrupt();
        const byte = client.reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (client.reader.error_state orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
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
    const wanted_line: u32 = @as(u32, @intCast(line.id));
    const track_line = blk: {
        for (track.lines.items) |*t| {
            if (t.line == wanted_line) break :blk t;
        }
        return error.InvalidResponse;
    };
    const wanted_carrier_id: u32 = ids[0];
    const carrier = blk: {
        for (track_line.carrier_state.items) |c| {
            if (c.id == wanted_carrier_id) break :blk c;
        }
        return error.CarrierNotFound;
    };
    const location = carrier.position;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
}
