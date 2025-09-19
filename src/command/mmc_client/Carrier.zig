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
    var wait_timer = try std.time.Timer.start();
    const socket = client.sock orelse return error.ServerNotConnected;
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        {
            try socket.waitToWrite(command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try api.request.info.system.encode(
                allocator,
                &writer.interface,
                .{
                    .line_id = line_id,
                    .carrier = true,
                    .source = .{
                        .carriers = .{ .ids = ids },
                    },
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var system = try api.response.info.system.decode(
            client.allocator,
            &reader.interface,
        );
        defer system.deinit(client.allocator);
        if (system.line_id != line_id) return error.InvalidResponse;
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == state) return;
    }
}
