const std = @import("std");
const client = @import("../../MmcClient.zig");
const command = @import("../../../command.zig");
const disconnect = @import("disconnect.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "connect");
    defer tracy_zone.end();
    if (client.get().sock) |_| disconnect.impl(&.{}) catch unreachable;
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
                    .host = try client.get().allocator.dupe(
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
                .host = try client.get().allocator.dupe(
                    u8,
                    params[0][0..last_delimiter_idx],
                ),
            };
        } else if (client.get().endpoint == null) .{
            .host = try client.get().allocator.dupe(u8, client.get().config.host),
            .port = client.get().config.port,
        } else .{
            .host = switch (client.get().endpoint.?.addr) {
                .ipv4 => |ipv4| try std.fmt.allocPrint(
                    client.get().allocator,
                    "{f}",
                    .{ipv4},
                ),
                .ipv6 => |ipv6| ipv6: {
                    const format = try std.fmt.allocPrint(
                        client.get().allocator,
                        "{f}",
                        .{ipv6},
                    );
                    defer client.get().allocator.free(format);
                    // Remove the square bracket from ipv6
                    break :ipv6 try std.fmt.allocPrint(
                        client.get().allocator,
                        "{s}",
                        .{format[1 .. format.len - 1]},
                    );
                },
            },
            .port = client.get().endpoint.?.port,
        };
    defer client.get().allocator.free(endpoint.host);
    std.log.info(
        "Trying to connect to {s}:{d}",
        .{ endpoint.host, endpoint.port },
    );
    const net = try client.zignet.Socket.connectToHost(
        client.get().allocator,
        endpoint.host,
        endpoint.port,
        &command.checkCommandInterrupt,
        3000,
    );
    client.get().endpoint = try net.getRemoteEndPoint();
    client.get().sock = net;
    errdefer {
        for (client.get().lines) |*line| {
            line.deinit(client.get().allocator);
        }
        client.get().allocator.free(client.get().lines);
        client.get().sock = null;
        net.close();
    }
    // Request server information, for matching API and getting server name.
    const server_request: api.protobuf.mmc.Request = .{
        .body = .{
            .core = .{ .kind = .CORE_REQUEST_KIND_SERVER_INFO },
        },
    };
    try client.sendRequest(client.get().allocator, net, server_request);
    var server_decoded = try client.getResponse(client.get().allocator, net);
    defer server_decoded.deinit(client.get().allocator);
    const server = switch (server_decoded.body orelse
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

    // API matching
    const server_api_version = server.api orelse return error.InvalidResponse;
    if (api.protobuf.version.major != server_api_version.major or
        api.protobuf.version.minor > server_api_version.minor)
    {
        std.log.info(
            "Client API version: {f}, Server API version: {}.{}.{}",
            .{
                api.protobuf.version,
                server_api_version.major,
                server_api_version.minor,
                server_api_version.patch,
            },
        );
        return error.APIVersionMismatch;
    }
    // Track configuration request
    const track_request: api.protobuf.mmc.Request = .{
        .body = .{
            .core = .{ .kind = .CORE_REQUEST_KIND_TRACK_CONFIG },
        },
    };
    try client.sendRequest(client.get().allocator, net, track_request);
    var track_decoded = try client.getResponse(client.get().allocator, net);
    defer track_decoded.deinit(client.get().allocator);
    const track_config = switch (track_decoded.body orelse
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
    client.get().lines = try client.get().allocator.alloc(
        client.Line,
        track_config.lines.items.len,
    );
    errdefer {
        for (client.get().lines) |*line| {
            line.deinit(client.get().allocator);
        }
        client.get().allocator.free(client.get().lines);
    }
    for (
        track_config.lines.items,
        client.get().lines,
        0..,
    ) |config, *line, idx| {
        line.* = try client.Line.init(
            client.get().allocator,
            @intCast(idx),
            config,
        );
        try client.get().parameter.value.line.items.insert(config.name);
    }
    // Initialize memory for logging configuration
    client.get().log_config =
        try client.log.Config.init(client.get().allocator, client.get().lines);
    errdefer client.get().log_config.deinit(client.get().allocator);
    // Displaying track configuration
    std.log.info("Track configuration for {s}:", .{server.name});
    var stdout = std.fs.File.stdout().writer(&.{});
    for (client.get().lines) |line| {
        try stdout.interface.print(
            "\t {s} ({}) - {} {s} | {} {s}\n",
            .{
                line.name,
                line.axes,
                line.velocity,
                client.standard.speed.unit,
                line.acceleration,
                client.standard.acceleration.unit,
            },
        );
        try stdout.interface.flush();
    }
    std.log.info("Connected to {f}", .{try net.getRemoteEndPoint()});
}
