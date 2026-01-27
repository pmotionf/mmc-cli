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

pub fn axisEmpty(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_axis_empty");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    if (client.sock == null) return error.ServerNotConnected;
    const line_name = params[0];
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
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var lines: std.ArrayList(u32) = .{};
    defer lines.deinit(client.allocator);
    try lines.append(client.allocator, @as(u32, @intCast(line.id)));
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
                            .lines = lines,
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
        const axis = track_line.axis_state.pop() orelse return error.InvalidResponse;
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
    if (client.sock == null) return error.ServerNotConnected;
    var ids = [1]u32{id};
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        var lines: std.ArrayList(u32) = .{};
        defer lines.deinit(client.allocator);
        try lines.append(client.allocator, line);
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
        const wanted_line: u32 = @as(u32, @intCast(line));
        const track_line = blk: {
            for (track.lines.items) |*t| {
                if (t.line == wanted_line) break :blk t;
            }
            return error.InvalidResponse;
        };
        // If a carrier is not found, it shall not return error.CarrierNotFound.
        // Every wait command shall be guaranteed by the user to be available
        // even after some time the carrier not found, e.g. when pulling
        // a carrier from different line.
        const carrier = track_line.carrier_state.pop() orelse continue;
        if (carrier.state == .CARRIER_STATE_OVERCURRENT) return error.Overcurrent;
        if (carrier.state == state) return;
    }
}
