const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const disconnect = @import("disconnect.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

const Standard = client.Standard;
const standard: Standard = .{};

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "connect");
    defer tracy_zone.end();
    if (client.stream) |_| disconnect.impl(io, &.{}) catch unreachable;
    // Parse endpoint
    const endpoint: union(enum) {
        hostname: std.Io.net.HostName,
        ip_address: std.Io.net.IpAddress,
    }, const port: u16 = endpoint: {
        if (params[0].len != 0) {
            const last_delimiter_idx = std.mem.lastIndexOf(
                u8,
                params[0],
                ":",
            ) orelse return error.MissingPort;
            // Parse port
            const port = std.fmt.parseInt(
                u16,
                params[0][last_delimiter_idx + 1 ..],
                0,
            ) catch return error.InvalidPort;
            // Resolve IP address
            if (std.Io.net.IpAddress.resolve(
                io,
                params[0][0..last_delimiter_idx],
                port,
            )) |address| {
                break :endpoint .{ .{ .ip_address = address }, port };
            } else |_| {
                // Use the parameter as hostname
                break :endpoint .{
                    .{
                        .hostname = try .init(params[0][0..last_delimiter_idx]),
                    },
                    port,
                };
            }
        } else if (client.endpoint) |endpoint| {
            break :endpoint .{
                .{ .ip_address = endpoint },
                endpoint.getPort(),
            };
        } else {
            // Resolve IP address
            if (std.Io.net.IpAddress.resolve(
                io,
                client.config.host,
                client.config.port,
            )) |address| {
                break :endpoint .{
                    .{ .ip_address = address },
                    client.config.port,
                };
            } else |_| {
                // Use the parameter as hostname
                break :endpoint .{
                    .{ .hostname = try .init(client.config.host) },
                    client.config.port,
                };
            }
        }
    };
    // TODO: Interrupt if ctrl+c is pressed
    const net = switch (endpoint) {
        .hostname => |hostname| net: {
            std.log.info(
                "Trying to connect to {s}:{}",
                .{ hostname.bytes, port },
            );
            break :net try hostname.connect(io, port, .{ .mode = .stream });
        },
        .ip_address => |address| net: {
            std.log.info("Trying to connect to {f}", .{address});
            break :net try address.connect(io, .{ .mode = .stream });
        },
    };
    // Store net to global client
    client.stream = net;
    errdefer {
        for (client.lines) |*line| {
            line.deinit(client.allocator);
        }
        client.allocator.free(client.lines);
        client.stream = null;
        net.socket.close(io);
    }
    std.log.debug("Send API version request..", .{});
    // Asserting that API version matched between client and server
    {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .core = .{ .kind = .CORE_REQUEST_KIND_API_VERSION },
            },
        };
        try client.sendRequest(io, client.allocator, net, request);
        var response = try client.readResponse(io, client.allocator, net);
        defer response.deinit(client.allocator);
        const server_api_version = switch (response.body orelse
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
    }
    // Getting track configuration
    {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .core = .{ .kind = .CORE_REQUEST_KIND_TRACK_CONFIG },
            },
        };
        try client.sendRequest(io, client.allocator, net, request);
        var response = try client.readResponse(io, client.allocator, net);
        defer response.deinit(client.allocator);
        const track_config = switch (response.body orelse
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
            try client.parameter.value.line.items.insert(config.name);
        }
    }
    {
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
        std.log.info("Track configuration for {s}:", .{server.name});
        var stdout = std.Io.File.stdout().writer(io, &.{});
        for (client.lines) |line| {
            try stdout.interface.print(
                "\t {s} ({}) - {} {s} | {} {s}\n",
                .{
                    line.name,
                    line.axes,
                    @as(f32, @floatFromInt(line.velocity.value)) /
                        @as(f32, if (line.velocity.low) 10 else 0.01),
                    standard.speed.unit,
                    @as(f32, @floatFromInt(line.acceleration)) * 100,
                    standard.acceleration.unit,
                },
            );
            try stdout.interface.flush();
        }
    }
    // Initialize memory for logging configuration
    client.log_config =
        try client.log.Config.init(client.allocator, client.lines);
    const remote_endpoint = try getRemoteEndPoint(net);
    // Store the newly connected server as the new client endpoint.
    std.log.info("Connected to {f}", .{remote_endpoint});
    client.endpoint = remote_endpoint;
}

// Get the connected endpoint
pub fn getRemoteEndPoint(
    stream: std.Io.net.Stream,
) (std.posix.GetSockNameError)!std.Io.net.IpAddress {
    var sockaddr: std.posix.sockaddr.storage = undefined;
    var sockaddr_len: std.posix.socklen_t =
        @sizeOf(std.posix.sockaddr.storage);
    const sockaddr_ptr: *std.posix.sockaddr = @ptrCast(&sockaddr);
    try std.posix.getpeername(stream.socket.handle, sockaddr_ptr, &sockaddr_len);
    if (sockaddr_ptr.family == std.posix.AF.INET) {
        const value: *align(4) const std.posix.sockaddr.in =
            @ptrCast(@alignCast(sockaddr_ptr));
        return .{
            .ip4 = .{
                .port = std.mem.bigToNative(u16, value.port),
                .bytes = @bitCast(value.addr),
            },
        };
    } else if (sockaddr_ptr.family == std.posix.AF.INET6) {
        const value: *align(4) const std.posix.sockaddr.in6 =
            @ptrCast(@alignCast(sockaddr_ptr));
        return .{
            .ip6 = .{
                .port = std.mem.bigToNative(u16, value.port),
                .bytes = @bitCast(value.addr),
                .interface = .{ .index = value.scope_id },
            },
        };
    } else return error.Unexpected;
}
