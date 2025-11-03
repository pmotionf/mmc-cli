const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const chrono = @import("chrono");
const tracy = @import("tracy");
const api = @import("mmc-api");
const zignet = @import("zignet");

const Kind = enum { all, axis, driver };
const Range = struct { start: u32 = 0, end: u32 = 0 };

pub fn add(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "add_log");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    // Parsing line name
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    // Parsing logging kind
    const kind: Kind = kind: {
        if (params[1].len == 0)
            return error.MissingParameter
        else if (std.mem.eql(u8, "all", params[1]))
            break :kind .all
        else if (std.mem.eql(u8, "axis", params[1]))
            break :kind .axis
        else if (std.mem.eql(u8, "driver", params[1]))
            break :kind .driver
        else
            return error.InvalidKind;
    };
    // Parsing logging range
    const range: Range = range: {
        if (params[2].len == 0)
            break :range .{ .start = 1, .end = line.axes }
        else {
            var range_iterator = std.mem.tokenizeSequence(u8, params[2], ":");
            const start_range = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            );
            const end_range = if (range_iterator.next()) |end|
                try std.fmt.parseInt(u32, end, 0)
            else
                start_range;
            break :range .{ .start = start_range, .end = end_range };
        }
    };
    if ((range.start < 1 and
        range.start > line.axes) or
        (range.end < 1 and
            range.end > line.axes))
        return error.InvalidAxis;
    // NOTE: There is no way to revert what is already toggled on the log. Thus,
    // the only thing that can be shown from this point is to always show the
    // logging configuration even if there is an error when trying to toggle
    // the driver flag for logging.
    defer status(&.{}) catch {};
    try modify(socket, line, kind, range, true);
}

pub fn start(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "start_log");
    defer tracy_zone.end();
    const duration = try std.fmt.parseFloat(f64, params[0]);
    const file_path = if (params[1].len > 0) params[1] else p: {
        var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(timestamp / std.time.s_per_day);
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(timestamp % std.time.s_per_day);
        const time = try chrono.Time.fromNumSecondsFromMidnight(
            time_day,
            0,
        );
        break :p try std.fmt.allocPrint(
            client.allocator,
            "mmc-logging-{}.{:0>2}.{:0>2}-{:0>2}.{:0>2}.{:0>2}.csv",
            .{
                ymd.year,
                ymd.month.number(),
                ymd.day,
                time.hour(),
                time.minute(),
                time.second(),
            },
        );
    };
    const log_thread = try std.Thread.spawn(
        .{},
        client.log.runner,
        .{ duration, try client.allocator.dupe(u8, file_path) },
    );
    log_thread.detach();
}

pub fn status(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "status_log");
    defer tracy_zone.end();
    std.log.info("Logging configuration:", .{});
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer stdout.interface.flush() catch {};
    for (client.log_config.lines) |line| {
        if (line.isInitialized() == false) continue;
        try stdout.interface
            .print("Line {s}: ", .{client.lines[line.id - 1].name});
        var axis_range: Range = .{};
        var driver_range: Range = .{};
        var first_axis_entry = true;
        var first_driver_entry = true;
        try stdout.interface.print("axis: [", .{});
        for (line.axes, 1..) |axis, axis_id| {
            if (axis == false) {
                if (axis_range.start == 0)
                    continue
                else if (axis_range.start == axis_range.end) {
                    if (first_axis_entry) first_axis_entry = false else {
                        try stdout.interface.print(",", .{});
                    }
                    try stdout.interface.print("{d}", .{axis_range.start});
                } else {
                    if (first_axis_entry) first_axis_entry = false else {
                        try stdout.interface.print(",", .{});
                    }
                    try stdout.interface.print(
                        "{d}-{d}",
                        .{ axis_range.start, axis_range.end },
                    );
                }
                axis_range = .{};
                continue;
            }
            if (axis_range.start == 0)
                axis_range =
                    .{ .start = @intCast(axis_id), .end = @intCast(axis_id) }
            else
                axis_range.end = @intCast(axis_id);
        }
        if (axis_range.start == 0) {
            // Do nothing
        } else if (axis_range.start == axis_range.end) {
            if (first_axis_entry) first_axis_entry = false else {
                try stdout.interface.print(",", .{});
            }
            try stdout.interface.print("{d}", .{axis_range.start});
        } else {
            if (first_axis_entry) first_axis_entry = false else {
                try stdout.interface.print(",", .{});
            }
            try stdout.interface.print(
                "{d}-{d}",
                .{ axis_range.start, axis_range.end },
            );
        }
        try stdout.interface.print("], driver: [", .{});
        for (line.drivers, 1..) |driver, driver_id| {
            if (driver == false) {
                if (driver_range.start == 0)
                    continue
                else if (driver_range.start == driver_range.end) {
                    if (first_driver_entry) first_driver_entry = false else {
                        try stdout.interface.print(",", .{});
                    }
                    try stdout.interface.print("{d}", .{driver_range.start});
                } else {
                    if (first_driver_entry) first_driver_entry = false else {
                        try stdout.interface.print(",", .{});
                    }
                    try stdout.interface.print(
                        "{d}-{d}",
                        .{ driver_range.start, driver_range.end },
                    );
                }
                driver_range = .{};
                continue;
            }
            if (driver_range.start == 0)
                driver_range =
                    .{ .start = @intCast(driver_id), .end = @intCast(driver_id) }
            else
                driver_range.end = @intCast(driver_id);
        }
        if (driver_range.start == 0) {
            // Do nothing
        } else if (driver_range.start == driver_range.end) {
            if (first_driver_entry) first_driver_entry = false else {
                try stdout.interface.print(",", .{});
            }
            try stdout.interface.print("{d}", .{driver_range.start});
        } else {
            if (first_driver_entry) first_driver_entry = false else {
                try stdout.interface.print(",", .{});
            }
            try stdout.interface.print(
                "{d}-{d}",
                .{ driver_range.start, driver_range.end },
            );
        }
        try stdout.interface.print("]\n", .{});
    }
}

pub fn remove(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "add_log");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    // Parsing line name
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    // Parsing logging kind
    const kind: Kind = kind: {
        if (params[1].len == 0)
            return error.MissingParameter
        else if (std.mem.eql(u8, "all", params[1]))
            break :kind .all
        else if (std.mem.eql(u8, "axis", params[1]))
            break :kind .axis
        else if (std.mem.eql(u8, "driver", params[1]))
            break :kind .driver
        else
            return error.InvalidKind;
    };
    // Parsing logging range
    const range: Range = range: {
        if (params[2].len == 0)
            break :range .{ .start = 1, .end = line.axes }
        else {
            var range_iterator = std.mem.tokenizeSequence(u8, params[2], ":");
            const start_range = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            );
            const end_range = if (range_iterator.next()) |end|
                try std.fmt.parseInt(u32, end, 0)
            else
                start_range;
            break :range .{ .start = start_range, .end = end_range };
        }
    };
    if ((range.start < 1 and
        range.start > line.axes) or
        (range.end < 1 and
            range.end > line.axes))
        return error.InvalidAxis;
    // NOTE: There is no way to revert what is already toggled on the log. Thus,
    // the only thing that can be shown from this point is to always show the
    // logging configuration even if there is an error when trying to toggle
    // the driver flag for logging.
    defer status(&.{}) catch {};
    try modify(socket, line, kind, range, false);
}

fn modify(
    socket: zignet.Socket,
    line: client.Line,
    kind: Kind,
    range: Range,
    comptime flag: bool,
) !void {
    for (range.start..range.end + 1) |axis_id| {
        if (kind == .all or kind == .axis)
            client.log_config.lines[line.index].axes[axis_id - 1] = flag;
        if (kind == .all or kind == .driver) {
            // Since the client does not know on which driver the axis is
            // located, the client has to request driver info with axis filter.
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .info = .{
                        .body = .{
                            .track = .{
                                .line = line.id,
                                .info_driver_state = true,
                                .filter = .{
                                    .axes = .{
                                        .start = @intCast(axis_id),
                                        .end = @intCast(axis_id),
                                    },
                                },
                            },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            // Send message
            try request.encode(&client.writer.interface, client.allocator);
            try client.writer.interface.flush();
            // Receive message
            try socket.waitToRead(&command.checkCommandInterrupt);
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
            const driver = track.driver_state.pop() orelse
                return error.InvalidResponse;
            client.log_config.lines[line.index].drivers[driver.id - 1] = flag;
        }
    }
}
