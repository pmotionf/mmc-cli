const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(_: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.core.encode(
            client.allocator,
            &writer.interface,
            .CORE_REQUEST_KIND_SERVER_INFO,
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var server = try client.api.response.core.server.decode(
        client.allocator,
        &reader.interface,
    );
    defer server.deinit(client.allocator);
    const version = server.version.?;
    const name = server.name;
    std.log.info(
        "{s} server version: {d}.{d}.{d}\n",
        .{ name, version.major, version.minor, version.patch },
    );
}
