const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn isolate(io: std.Io, params: [][]const u8) !void {
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
        io,
        line.id,
        carrier_id,
        .CARRIER_STATE_INITIALIZE_COMPLETED,
        timeout,
    );
}

pub fn moveCarrier(io: std.Io, params: [][]const u8) !void {
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
        io,
        line.id,
        carrier_id,
        .CARRIER_STATE_MOVE_COMPLETED,
        timeout,
    );
}

pub fn axisEmpty(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "wait_axis_empty");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
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
    io: std.Io,
    line: u32,
    id: std.math.IntFittingRange(1, 1023),
    state: api.protobuf.mmc.info.Response.Track.Carrier.State.State,
    timeout: u64,
) !void {
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
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
        if (track.line != line) return error.InvalidResponse;
        // If a carrier is not found, it shall not return error.CarrierNotFound.
        // Every wait command shall be guaranteed by the user to be available
        // even after some time the carrier not found, e.g. when pulling
        // a carrier from different line.
        const carrier = track.carrier_state.pop() orelse continue;
        if (carrier.state == .CARRIER_STATE_OVERCURRENT) return error.Overcurrent;
        if (carrier.state == state) return;
    }
}
