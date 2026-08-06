const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const disconnect = @import("disconnect.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "connect");
    defer tracy_zone.end();
    if (client.sock) |_| disconnect.impl(io, gpa, &.{}) catch unreachable;
    const net: std.Io.net.Stream = stream: {
        if (params[0].len != 0) {
            const last_delimiter_idx =
                std.mem.lastIndexOf(u8, params[0], ":") orelse
                return error.MissingPort;
            const port: u16 = std.fmt.parseInt(
                u16,
                params[0][last_delimiter_idx + 1 ..],
                0,
            ) catch return error.InvalidPort;
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
                const address: std.Io.net.IpAddress = try .resolveIp6(
                    io,
                    params[0][1 .. last_delimiter_idx - 1],
                    port,
                );
                std.log.info("Trying to connect to {f}", .{address});
                break :stream try address.connect(
                    io,
                    .{
                        .mode = .stream,
                        .protocol = .tcp,
                    },
                );
            }
            const address: std.Io.net.IpAddress = try .parse(
                params[0][0..last_delimiter_idx],
                port,
            );
            std.log.info("Trying to connect to {f}", .{address});
            break :stream try address.connect(
                io,
                .{ .mode = .stream, .protocol = .tcp },
            );
        } else if (client.endpoint == null) {
            const address: std.Io.net.IpAddress = try .parse(
                client.config.host,
                client.config.port,
            );
            std.log.info("Trying to connect to {f}", .{address});
            break :stream try address.connect(
                io,
                .{ .mode = .stream, .protocol = .tcp },
            );
        } else {
            const address = client.endpoint.?;
            std.log.info("Trying to connect to {f}", .{address});
            break :stream try address.connect(
                io,
                .{ .mode = .stream, .protocol = .tcp },
            );
        }
    };
    client.endpoint = net.socket.address;
    client.sock = net;
    errdefer {
        for (client.lines) |*line| {
            line.deinit(gpa);
        }
        gpa.free(client.lines);
        client.sock = null;
        net.close(io);
    }
    // Request server information, for matching API and getting server name.
    const server_request: api.protobuf.mmc.Request = .{
        .body = .{
            .core = .{ .kind = .CORE_REQUEST_KIND_SERVER_INFO },
        },
    };
    try client.sendRequest(io, gpa, net, server_request);
    var server_decoded = try client.getResponse(gpa, io, net);
    defer server_decoded.deinit(gpa);
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
    try client.sendRequest(io, gpa, net, track_request);
    var track_decoded = try client.getResponse(gpa, io, net);
    defer track_decoded.deinit(gpa);
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
    client.lines = try gpa.alloc(
        client.Line,
        track_config.lines.items.len,
    );
    errdefer {
        for (client.lines) |*line| {
            line.deinit(gpa);
        }
        gpa.free(client.lines);
    }
    for (
        track_config.lines.items,
        client.lines,
        0..,
    ) |config, *line, idx| {
        line.* = try client.Line.init(
            gpa,
            @intCast(idx),
            config,
        );
        try client.parameter.value.line.items.insert(config.name);
    }
    // Initialize memory for logging configuration
    client.log_config =
        try client.log.Config.init(gpa, client.lines);
    errdefer client.log_config.deinit(gpa);
    // Displaying track configuration
    std.log.info("Track configuration for {s}:", .{server.name});
    var stdout = std.Io.File.stdout().writer(io, &.{});
    for (client.lines) |line| {
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
    std.log.info("Connected to {f}", .{net.socket.address});
}

test {
    std.testing.refAllDecls(@This());
}
