//! This file contains callbacks for managing the connection with the server.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const callbacks = @import("../callbacks.zig");
const command = @import("../../../command.zig");

pub fn connect(params: [][]const u8) !void {
    if (client.sock) |_| client.disconnect();
    const endpoint: client.Config =
        if (params[0].len != 0) endpoint: {
            var iterator = std.mem.tokenizeSequence(
                u8,
                params[0],
                ":",
            );
            const host = try client.allocator.dupe(
                u8,
                iterator.next() orelse return error.InvalidHost,
            );
            errdefer client.allocator.free(host);
            if (host.len > 63) return error.InvalidEndpoint;
            break :endpoint .{
                .host = host,
                .port = std.fmt.parseInt(
                    u16,
                    iterator.next() orelse return error.MissingParameter,
                    0,
                ) catch return error.InvalidEndpoint,
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
    );
    errdefer socket.close();
    std.log.info(
        "Connected to {s}:{d}",
        .{ endpoint.host, endpoint.port },
    );
    std.log.debug("Send API version request..", .{});
    // Asserting that API version matched between client and server
    {
        // Send API version request
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.core.encode(
            client.allocator,
            &writer.interface,
            .CORE_REQUEST_KIND_API_VERSION,
        );
        try writer.interface.flush();
    }
    std.log.debug("Asserting API version..", .{});
    {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        const response = try client.api.response.core.api_version.decode(
            client.allocator,
            &reader.interface,
        );
        if (client.api.api.version.major != response.major or
            client.api.api.version.minor != response.minor)
        {
            return error.APIVersionMismatch;
        }
    }
    std.log.debug("Sending track config request..", .{});
    {
        // Send line configuration request
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.core.encode(
            client.allocator,
            &writer.interface,
            .CORE_REQUEST_KIND_TRACK_CONFIG,
        );
        try writer.interface.flush();
    }
    std.log.debug("Getting track configuration..", .{});
    {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var response = try client.api.response.core.track_config.decode(
            client.allocator,
            &reader.interface,
        );
        defer response.deinit(client.allocator);
        client.lines = try client.allocator.alloc(
            client.Line,
            response.lines.items.len,
        );
        for (
            response.lines.items,
            client.lines,
            0..,
        ) |config, *line, idx| {
            std.log.debug("{}", .{config});
            line.* = try client.Line.init(
                client.allocator,
                @intCast(idx),
                config,
            );
        }
    }
    std.log.info(
        "Received the line configuration for the following line(s):",
        .{},
    );
    var stdout = std.fs.File.stdout().writer(&.{});
    for (client.lines) |line| {
        try stdout.interface.writeByte('\t');
        try stdout.interface.writeAll(line.name);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
    }
    const sockaddr: *const std.posix.sockaddr = switch (socket.sockaddr) {
        .any => |any| &any,
        .ipv4 => |in| @ptrCast(&in),
        .ipv6 => |in6| @ptrCast(&in6),
    };
    client.endpoint = try .fromSockAddr(sockaddr);
    client.sock = socket;
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

/// Serve as a callback of a `DISCONNECT` command, requires parameter.
pub fn disconnect(_: [][]const u8) error{ServerNotConnected}!void {
    if (client.sock) |_| client.disconnect() else return error.ServerNotConnected;
    std.log.info(
        "Disconnected from {f}:{}",
        .{ client.endpoint.?.addr, client.endpoint.?.port },
    );
}
