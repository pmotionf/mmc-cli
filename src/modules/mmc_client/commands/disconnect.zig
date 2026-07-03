const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

/// Free all memory EXCEPT the endpoint, so that the client can reconnect to the
/// latest server
pub fn impl(_: std.Io, gpa: std.mem.Allocator, _: [][]const u8) error{ServerNotConnected}!void {
    const tracy_zone = tracy.traceNamed(@src(), "disconnect");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
    client.log.stop.store(true, .monotonic);
    // Wait until the log finish storing log data and cleanup
    while (client.log.executing.load(.monotonic)) {}
    client.parameter.reset();
    client.log_config.deinit(gpa);
    net.close();
    client.sock = null;
    for (client.lines) |*line| {
        line.deinit(gpa);
    }
    gpa.free(client.lines);
    client.lines = &.{};
    std.log.info(
        "Disconnected from {f}:{}",
        .{ client.endpoint.?.addr, client.endpoint.?.port },
    );
}
