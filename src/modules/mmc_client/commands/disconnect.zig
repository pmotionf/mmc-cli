const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

/// Free all memory EXCEPT the endpoint, so that the client can reconnect to the
/// latest server
pub fn impl(_: [][]const u8) error{ServerNotConnected}!void {
    const tracy_zone = tracy.traceNamed(@src(), "disconnect");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
    client.log.stop.store(true, .monotonic);
    // Wait until the log finish storing log data and cleanup
    while (client.log.executing.load(.monotonic)) {}
    client.parameter.reset();
    client.log_config.deinit(client.allocator);
    net.close();
    client.sock = null;
    for (client.lines) |*line| {
        line.deinit(client.allocator);
    }
    client.allocator.free(client.lines);
    client.lines = &.{};
    std.log.info(
        "Disconnected from {f}:{}",
        .{ client.endpoint.?.addr, client.endpoint.?.port },
    );
}
