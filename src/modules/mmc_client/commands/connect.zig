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
            // IPv6 address shall be provided with square brackets. In addition,
            // Ipv6 address has at least 2 ":" characters, with the port
            // separator makes it 3 characters.
            if (std.mem.count(u8, params[0], ":") > 2 and
                std.mem.eql(u8, "[", params[0][0..1]) and
                std.mem.eql(
                    u8,
                    "]",
                    params[0][last_delimiter_idx - 1 .. last_delimiter_idx],
                ))
            {
                // IPv6 address shall be provided with scope id. Required for
                // local connection.
                if (std.mem.count(u8, params[0], "%") == 0)
                    return error.MissingScopeId;
                break :endpoint .{
                    .port = std.fmt.parseInt(
                        u16,
                        params[0][last_delimiter_idx + 1 ..],
                        0,
                    ) catch return error.InvalidEndpoint,
                    .host = try client.allocator.dupe(
                        u8,
                        params[0][1 .. last_delimiter_idx - 1],
                    ),
                };
            }
            // IPv4 address or hostname logic.
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
            .host = switch (client.endpoint.?.addr) {
                .ipv4 => |ipv4| try std.fmt.allocPrint(
                    client.allocator,
                    "{f}",
                    .{ipv4},
                ),
                .ipv6 => |ipv6| ipv6: {
                    const format = try std.fmt.allocPrint(
                        client.allocator,
                        "{f}",
                        .{ipv6},
                    );
                    defer client.allocator.free(format);
                    // Remove the square bracket from ipv6
                    break :ipv6 try std.fmt.allocPrint(
                        client.allocator,
                        "{s}",
                        .{format[1 .. format.len - 1]},
                    );
                },
            },
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
        3000,
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
    }
    {
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
        std.log.info("Track configuration for {s}:", .{server.name});
        var stdout = std.fs.File.stdout().writer(&.{});
        for (client.lines) |line| {
            try stdout.interface.print(
                // "\t {s} ({})\t\t ({} m/s - {} m/s^2)\n",
                "\t {s} ({}) - {}m/s | {}m/s^2\n",
                .{
                    line.name, line.axes,
                    @as(f32, @floatFromInt(line.velocity.value)) /
                        @as(f32, if (line.velocity.low) 10_000 else 10.0),
                    @as(f32, @floatFromInt(line.acceleration)) / 10.0,
                },
            );
            try stdout.interface.flush();
        }
    }
    // Initialize memory for logging configuration
    client.log_config =
        try client.log.Config.init(client.allocator, client.lines);
}
