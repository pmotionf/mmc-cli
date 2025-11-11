const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn isolate(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_isolate");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, b: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try waitCarrierState(
        line.id,
        carrier_id,
        .CARRIER_STATE_INITIALIZE_COMPLETED,
        timeout,
    );
}

pub fn moveCarrier(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_move_carrier");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, b: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try waitCarrierState(
        line.id,
        carrier_id,
        .CARRIER_STATE_MOVE_COMPLETED,
        timeout,
    );
}

pub fn pull(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_pull");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, b: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try waitCarrierState(
        line.id,
        carrier_id,
        .CARRIER_STATE_PULL_COMPLETED,
        timeout,
    );
}

pub fn axisEmpty(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_axis_empty");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
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
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
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
        if (axis.carrier == 0 and
            !axis.hall_alarm_back and
            !axis.hall_alarm_front and
            !axis.waiting_push and
            !axis.waiting_pull)
        {
            break;
        }
    }
}

fn waitCarrierState(
    line: u32,
    id: std.math.IntFittingRange(1, 1023),
    state: api.protobuf.mmc.info.Response.Track.Carrier.State.State,
    timeout: u64,
) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids = [1]u32{id};
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .info = .{
                    .body = .{
                        .track = .{
                            .line = line,
                            .info_carrier_state = true,
                            .filter = .{
                                .carriers = .{ .ids = .fromOwnedSlice(&ids) },
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
        // Receive response
        try socket.waitToRead();
        var decoded: api.protobuf.mmc.Response = try .decode(
            &client.reader.interface,
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
        if (track.line != line) return error.InvalidResponse;
        const carrier = track.carrier_state.pop() orelse return error.CarrierNotFound;
        if (carrier.state == .CARRIER_STATE_OVERCURRENT) return error.Overcurrent;
        if (carrier.state == state) return;
    }
}
