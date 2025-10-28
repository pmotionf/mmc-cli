const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

/// Free all memory EXCEPT the endpoint, so that the client can reconnect to the
/// latest server
pub fn impl(_: [][]const u8) error{ServerNotConnected}!void {
    const tracy_zone = tracy.traceNamed(@src(), "disconnect");
    defer tracy_zone.end();
    if (client.sock) |s| {
        client.Log.stop.store(true, .monotonic);
        // Wait until the log finish storing log data and cleanup
        while (client.Log.executing.load(.monotonic)) {}
        client.reader = undefined;
        client.writer = undefined;
        s.close();
        client.sock = null;
        client.log.deinit();
        for (client.lines) |*line| {
            line.deinit(client.allocator);
        }
        client.allocator.free(client.lines);
        client.lines = &.{};
        std.log.info(
            "Disconnected from {f}:{}",
            .{ client.endpoint.?.addr, client.endpoint.?.port },
        );
    } else return error.ServerNotConnected;
}
