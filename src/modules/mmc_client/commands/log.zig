const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const chrono = @import("chrono");
const tracy = @import("tracy");

pub fn add(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "add_log");
    defer tracy_zone.end();
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const kind = params[1];
    if (kind.len == 0) return error.MissingParameter;
    const line = client.lines[line_idx];
    const range = params[2];
    var log_range: client.Log.Config.Range = undefined;
    if (range.len > 0) {
        var range_iterator = std.mem.tokenizeSequence(u8, range, ":");
        log_range = .{
            .start = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
            .end = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
        };
    } else {
        log_range = .{ .start = 1, .end = line.axes };
    }
    if ((log_range.start < 1 and
        log_range.start > line.axes) or
        (log_range.end < 1 and
            log_range.end > line.axes))
        return error.InvalidAxis;
    if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("axis", kind) or
        std.ascii.eqlIgnoreCase("driver", kind))
    {} else return error.InvalidKind;
    client.log.configs[line_idx].axis =
        if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("axis", kind))
            true
        else
            false;
    client.log.configs[line_idx].driver =
        if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("driver", kind))
            true
        else
            false;
    client.log.configs[line_idx].axis_id_range = log_range;
    try client.log.status();
}

pub fn start(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "start_log");
    defer tracy_zone.end();
    errdefer client.log.reset();
    const duration = try std.fmt.parseFloat(f64, params[0]);
    const path = params[1];
    client.log.path = if (path.len > 0) path else p: {
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
        client.Log.handler,
        .{duration},
    );
    log_thread.detach();
}

pub fn status(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "status_log");
    defer tracy_zone.end();
    try client.log.status();
}

pub fn remove(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "remove_log");
    defer tracy_zone.end();
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        client.log.configs[line_idx].deinit(client.log.allocator);
    } else {
        for (client.log.configs) |*config| {
            config.deinit(client.log.allocator);
        }
    }
    try client.log.status();
}
