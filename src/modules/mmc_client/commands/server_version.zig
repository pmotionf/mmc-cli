const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, _: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "server_version");
    defer tracy_zone.end();
    const net = client.stream orelse return error.ServerNotConnected;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .core = .{ .kind = .CORE_REQUEST_KIND_SERVER_INFO },
        },
    };
    try client.sendRequest(io, client.allocator, net, request);
    var response = try client.readResponse(io, client.allocator, net);
    defer response.deinit(client.allocator);
    const server = switch (response.body orelse
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
