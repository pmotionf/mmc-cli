const Axis = @This();

const Driver = @import("Driver.zig");
const Line = @import("Line.zig");
const std = @import("std");
const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");
const api = @import("api.zig");
const SystemResponse = api.api.info_msg.Response.System;

driver: *const Driver,
index: Axis.Index,
id: Axis.Id,

/// TODO: When the maximum axis is provided in the line configuration, update
///       the following into a proper `Max` type. Right now, assume that the
///       both maximum number of axis of one line and one axis is still fix.
pub const max = struct {
    /// Maximum number of axes in a driver
    pub const driver = 3;
    /// Maximum number of axis in a line
    pub const line = Driver.max * max.driver;
};

pub const Index = struct {
    line: Index.Line,
    driver: Index.Driver,

    pub const Line = std.math.IntFittingRange(0, max.line - 1);
    pub const Driver = std.math.IntFittingRange(0, max.driver - 1);
};

pub const Id = struct {
    line: Id.Line,
    driver: Id.Driver,

    pub const Line = std.math.IntFittingRange(1, Axis.max.line);
    pub const Driver = std.math.IntFittingRange(1, Axis.max.driver);
};

pub fn waitEmpty(
    allocator: std.mem.Allocator,
    line_id: Line.Id,
    id: Id.Line,
    timeout: u64,
) !void {
    const msg = try api.request.info.system.encode(
        allocator,
        .{
            .line_id = line_id,
            .axis = true,
            .source = .{
                .axis_range = .{
                    .start_id = id,
                    .end_id = id,
                },
            },
        },
    );
    defer client.allocator.free(msg);
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        try client.net.send(msg);
        const resp = try client.net.receive(client.allocator);
        defer client.allocator.free(resp);
        var system = try api.response.info.system.decode(
            client.allocator,
            resp,
        );
        defer system.deinit();
        if (system.line_id != line_id) return error.InvalidResponse;
        const axis_info = system.axis_infos.pop() orelse return error.InvalidResponse;
        const carrier = axis_info.carrier_id;
        const axis_alarms = axis_info.hall_alarm orelse return error.InvalidResponse;
        const wait_push = axis_info.waiting_push;
        const wait_pull = axis_info.waiting_pull;
        if (carrier == 0 and !axis_alarms.back and !axis_alarms.front and
            !wait_pull and !wait_push)
        {
            break;
        }
    }
}
