const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "assert_hall");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
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
    const side: api.protobuf.mmc.command.Request.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .DIRECTION_BACKWARD
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .DIRECTION_FORWARD
        else
            return error.InvalidHallAlarmSide;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];

    var alarm_on: bool = true;
    if (params[3].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[3])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[3])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_axis_state = true,
                        .filter = .{
                            .axes = .{
                                .start = axis_id,
                                .end = axis_id,
                            },
                        },
                    },
                },
            },
        },
    };
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    // Receive response
    while (true) {
        try command.checkCommandInterrupt();
        const byte = net_reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (net_reader.err orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
    while (true) {
        try command.checkCommandInterrupt();
        const byte = net_reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (net_reader.err orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
    var proto_reader: std.Io.Reader = .fixed(net_reader.interface.buffered());
    var decoded: api.protobuf.mmc.Response = try .decode(
        &proto_reader,
        client.allocator,
    );
    defer decoded.deinit(client.allocator);
    var track = switch (decoded.body orelse return error.InvalidResponse) {
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
    const axis = track.axis_state.pop() orelse return error.InvalidResponse;
    switch (side) {
        .DIRECTION_BACKWARD => {
            if (axis.hall_alarm_back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .DIRECTION_FORWARD => {
            if (axis.hall_alarm_front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        else => return error.UnexpectedResponse,
    }
}
