const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(_: std.Io, _: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "server_version");
    defer tracy_zone.end();
    if (client.sock == null) return error.ServerNotConnected;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .core = .{ .kind = .CORE_REQUEST_KIND_SERVER_INFO },
        },
    };
    // Clear all buffer in reader and writer for safety.
    _ = client.reader.interface.discardRemaining() catch {};
    _ = client.writer.interface.consumeAll();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    // Receive response
    while (true) {
        try command.checkCommandInterrupt();
        const byte = client.reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (client.reader.error_state orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
    var decoded: api.protobuf.mmc.Response = try .decode(
        &client.reader.interface,
        client.allocator,
    );
    defer decoded.deinit(client.allocator);
    const server = switch (decoded.body orelse
        return error.InvalidResponse) {
        .core => |core_resp| switch (core_resp.body orelse
            return error.InvalidResponse) {
            .server => |server| server,
            .request_error => |req_err| {
                return client.error_response.throwCoreError(req_err);
            },
            else => return error.InvalidResponse,
        },
        .request_error => |req_err| {
            return client.error_response.throwMmcError(req_err);
        },
        else => return error.InvalidResponse,
    };
    const version = server.version orelse return error.InvalidResponse;
    const name = server.name;
    std.log.info(
        "{s} server version: {d}.{d}.{d}\n",
        .{ name, version.major, version.minor, version.patch },
    );
}
