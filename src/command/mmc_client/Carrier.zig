const std = @import("std");
const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");
const api = @import("api.zig");
const SystemResponse = api.api.protobuf.mmc.info.Response.Track;

pub const max = 2048;
pub const Id = std.math.IntFittingRange(1, max);

pub fn waitState(
    allocator: std.mem.Allocator,
    line: u32,
    id: Id,
    state: SystemResponse.Carrier.State.State,
    timeout: u64,
) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(allocator);
    try ids.append(allocator, id);
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try api.request.info.track.encode(
                allocator,
                &writer.interface,
                .{
                    .line = line,
                    .info_carrier_state = true,
                    .filter = .{
                        .carriers = .{ .ids = ids },
                    },
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line) return error.InvalidResponse;
        const carrier = track.carrier_state.pop() orelse return error.InvalidResponse;
        if (carrier.state == .CARRIER_STATE_OVERCURRENT) return error.Overcurrent;
        if (carrier.state == state) return;
    }
}
