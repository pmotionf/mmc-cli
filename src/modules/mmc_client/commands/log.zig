const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const chrono = @import("chrono");
const tracy = @import("tracy");
const api = @import("mmc-api");

const Kind = enum { all, axis, driver };

pub fn add(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "add_log");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
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
    const range: client.log.Range = range: {
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
    // the only thing that can be done from this point is to always show the
    // logging configuration even if there is an error when trying to toggle
    // the driver flag for logging.
    defer client.log_config.status() catch {};
    try modify(net, line, kind, range, true);
}

pub fn start(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "start_log");
    defer tracy_zone.end();
    if (client.log.executing.load(.monotonic) == true)
        return error.LoggingAlreadyStarted;
    const duration = try std.fmt.parseFloat(f64, params[0]);
    const path = params[1];
    const file_path = if (path.len > 0) p: {
        // Check if the specified path is ended in csv.
        if (std.mem.eql(u8, path[path.len - 4 .. path.len], ".csv"))
            break :p try client.allocator.dupe(u8, path);
        break :p try std.fmt.allocPrint(client.allocator, "{s}.csv", .{path});
    } else p: {
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
    defer client.allocator.free(file_path);
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
    try client.log_config.status();
}

pub fn remove(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "remove_log");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
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
    const range: client.log.Range = range: {
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
    defer client.log_config.status() catch {};
    try modify(net, line, kind, range, false);
}

pub fn stop(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "stop_log");
    defer tracy_zone.end();
    if (client.log.executing.load(.monotonic))
        client.log.stop.store(true, .monotonic)
    else
        return error.NoRunningLogging;
}

pub fn cancel(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "cancel_log");
    defer tracy_zone.end();
    if (client.log.executing.load(.monotonic))
        client.log.cancel.store(true, .monotonic)
    else
        return error.NoRunningLogging;
}

fn modify(
    net: client.zignet.Socket,
    line: client.Line,
    kind: Kind,
    range: client.log.Range,
    flag: bool,
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
            try client.sendRequest(client.allocator, net, request);
            var decoded = try client.getResponse(client.allocator, net);
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
