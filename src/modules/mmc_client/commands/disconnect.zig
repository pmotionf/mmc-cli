const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

/// Free all memory EXCEPT the endpoint, so that the client can reconnect to the
/// latest server
pub fn impl(_: [][]const u8) error{ServerNotConnected}!void {
    const tracy_zone = tracy.traceNamed(@src(), "disconnect");
    defer tracy_zone.end();
    const net = client.get().sock orelse return error.ServerNotConnected;
    client.log.stop.store(true, .monotonic);
    // Wait until the log finish storing log data and cleanup
    while (client.log.executing.load(.monotonic)) {}
    client.get().parameter.reset();
    client.get().log_config.deinit(client.get().allocator);
    net.close();
    client.get().sock = null;
    for (client.get().lines) |*line| {
        line.deinit(client.get().allocator);
    }
    client.get().allocator.free(client.get().lines);
    client.get().lines = &.{};
    std.log.info(
        "Disconnected from {f}:{}",
        .{ client.get().endpoint.?.addr, client.get().endpoint.?.port },
    );
}
