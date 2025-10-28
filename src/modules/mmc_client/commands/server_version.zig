const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");

pub fn impl(_: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "server_version");
    defer tracy_zone.end();
    const socket = client.sock orelse return error.ServerNotConnected;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        try client.api.request.core.encode(
            client.allocator,
            &client.writer.interface,
            .CORE_REQUEST_KIND_SERVER_INFO,
        );
        try client.writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var server = try client.api.response.core.server.decode(
        client.allocator,
        &client.reader.interface,
    );
    defer server.deinit(client.allocator);
    const version = server.version.?;
    const name = server.name;
    std.log.info(
        "{s} server version: {d}.{d}.{d}\n",
        .{ name, version.major, version.minor, version.patch },
    );
}
