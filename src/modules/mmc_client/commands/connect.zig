const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const disconnect = @import("disconnect.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "connect");
    defer tracy_zone.end();
    if (client.sock) |_| disconnect.impl(&.{}) catch unreachable;
    const endpoint: client.Config =
        if (params[0].len != 0) endpoint: {
            const last_delimiter_idx =
                std.mem.lastIndexOf(u8, params[0], ":") orelse
                return error.MissingPort;
            break :endpoint .{
                .port = std.fmt.parseInt(
                    u16,
                    params[0][last_delimiter_idx + 1 ..],
                    0,
                ) catch return error.InvalidEndpoint,
                .host = try client.allocator.dupe(
                    u8,
                    params[0][0..last_delimiter_idx],
                ),
            };
        } else if (client.endpoint == null) .{
            .host = try client.allocator.dupe(u8, client.config.host),
            .port = client.config.port,
        } else .{
            .host = try std.fmt.allocPrint(
                client.allocator,
                "{f}",
                .{client.endpoint.?.addr},
            ),
            .port = client.endpoint.?.port,
        };
    defer client.allocator.free(endpoint.host);
    std.log.info(
        "Trying to connect to {s}:{d}",
        .{ endpoint.host, endpoint.port },
    );
    const socket = try client.zignet.Socket.connectToHost(
        client.allocator,
        endpoint.host,
        endpoint.port,
        &command.checkCommandInterrupt,
    );
    client.endpoint = try socket.getRemoteEndPoint();
    client.sock = socket;
    client.reader = socket.reader(&client.reader_buf);
    client.writer = socket.writer(&client.writer_buf);
    errdefer {
        client.reader = undefined;
        client.writer = undefined;
        for (client.lines) |*line| {
            line.deinit(client.allocator);
        }
        client.allocator.free(client.lines);
        client.sock = null;
        socket.close();
    }
    std.log.info(
        "Connected to {f}",
        .{try socket.getRemoteEndPoint()},
    );
    std.log.debug("Send API version request..", .{});
    // Asserting that API version matched between client and server
    {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .core = .{ .kind = .CORE_REQUEST_KIND_API_VERSION },
            },
        };
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        // Receive response
        try socket.waitToRead();
        const decoded: api.protobuf.mmc.Response = try .decode(
            &client.reader.interface,
            client.allocator,
        );
        const server_api_version = switch (decoded.body orelse
            return error.InvalidResponse) {
            .core => |core_resp| switch (core_resp.body orelse
                return error.InvalidResponse) {
                .api_version => |api_version| api_version,
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
        if (api.version.major != server_api_version.major or
            api.version.minor > server_api_version.minor)
        {
            std.log.info(
                "Client API version: {f}, Server API version: {}.{}.{}",
                .{
                    api.version,
                    server_api_version.major,
                    server_api_version.minor,
                    server_api_version.patch,
                },
            );
            return error.APIVersionMismatch;
        }
    }
    // Getting track configuration
    {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .core = .{ .kind = .CORE_REQUEST_KIND_TRACK_CONFIG },
            },
        };
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite();
        // Send message
        try request.encode(&client.writer.interface, client.allocator);
        try client.writer.interface.flush();
        // Receive response
        try socket.waitToRead();
        var decoded: api.protobuf.mmc.Response = try .decode(
            &client.reader.interface,
            client.allocator,
        );
        defer decoded.deinit(client.allocator);
        const track_config = switch (decoded.body orelse
            return error.InvalidResponse) {
            .core => |core_resp| switch (core_resp.body orelse
                return error.InvalidResponse) {
                .track_config => |track_config| track_config,
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
        client.lines = try client.allocator.alloc(
            client.Line,
            track_config.lines.items.len,
        );
        for (
            track_config.lines.items,
            client.lines,
            0..,
        ) |config, *line, idx| {
            line.* = try client.Line.init(
                client.allocator,
                @intCast(idx),
                config,
            );
        }
        std.log.info(
            "Received the line configuration for the following {s}:",
            .{if (client.lines.len <= 1) "line" else "lines"},
        );
        var stdout = std.fs.File.stdout().writer(&.{});
        for (client.lines) |line| {
            try stdout.interface.writeByte('\t');
            try stdout.interface.writeAll(line.name);
            try stdout.interface.writeByte('\n');
            try stdout.interface.flush();
        }
    }
    // Initialize memory for logging configuration
    client.log = try client.Log.init(
        client.allocator,
        client.lines,
        client.endpoint.?,
    );
    for (client.log.configs, client.lines) |*config, line| {
        try config.init(client.allocator, line.id, line.name);
    }
}
