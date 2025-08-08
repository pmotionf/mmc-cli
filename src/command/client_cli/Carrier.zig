const Carrier = @This();

const std = @import("std");
const client = @import("../client_cli.zig");
const command = @import("../../command.zig");
const api = @import("api.zig");
const SystemResponse = api.api.info_msg.Response.System;

id: Id,
position: f32,
state: SystemResponse.Carrier.Info.State,
cas: struct { enabled: bool, triggered: bool },

pub const max = 2048;
pub const Id = std.math.IntFittingRange(1, max);

pub fn waitState(
    allocator: std.mem.Allocator,
    line_id: u32,
    id: Id,
    state: SystemResponse.Carrier.Info.State,
    timeout: u64,
) !void {
    var ids = [1]u32{id};
    const _ids = std.ArrayListAligned(
        u32,
        null,
    ).fromOwnedSlice(
        allocator,
        &ids,
    );
    defer _ids.deinit();
    const msg = try api.request.info.system.encode(
        allocator,
        .{
            .line_id = line_id,
            .carrier = true,
            .source = .{
                .carriers = .{ .ids = _ids },
            },
        },
    );
    var wait_timer = try std.time.Timer.start();
    defer client.allocator.free(msg);
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
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == state) return;
    }
}
