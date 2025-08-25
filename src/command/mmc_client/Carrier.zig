const std = @import("std");
const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");
const api = @import("api.zig");
const SystemResponse = api.api.info_msg.Response.System;

pub const max = 2048;
pub const Id = std.math.IntFittingRange(1, max);

pub fn waitState(
    allocator: std.mem.Allocator,
    line_id: u32,
    id: Id,
    state: SystemResponse.Carrier.Info.State,
    timeout: u64,
) !void {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(allocator);
    try ids.append(allocator, id);
    try api.request.info.system.encode(
        allocator,
        &client.writer.writer,
        .{
            .line_id = line_id,
            .carrier = true,
            .source = .{
                .carriers = .{ .ids = ids },
            },
        },
    );
    const msg = try client.writer.toOwnedSlice();
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
        var reader: std.Io.Reader = .fixed(resp);
        var system = try api.response.info.system.decode(
            client.allocator,
            &reader,
        );
        defer system.deinit(client.allocator);
        if (system.line_id != line_id) return error.InvalidResponse;
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == state) return;
    }
}
