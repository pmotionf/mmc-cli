const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");
const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");

const Filter = union(enum) {
    carrier: [1]u32,
    driver: u32,
    axis: u32,

    pub fn parse(filter: []const u8) (error{InvalidParameter} || std.fmt.ParseIntError)!Filter {
        if (filter.len < 2) return error.InvalidParameter;
        if (std.ascii.isDigit(filter[1])) {
            if (std.ascii.eqlIgnoreCase(filter[0..1], "c")) {
                return Filter{
                    .carrier = [1]u32{try std.fmt.parseUnsigned(u32, filter[1..], 0)},
                };
            } else if (std.ascii.eqlIgnoreCase(filter[0..1], "a")) {
                return Filter{
                    .axis = try std.fmt.parseUnsigned(u32, filter[1..], 0),
                };
            } else if (std.ascii.eqlIgnoreCase(filter[0..1], "d")) {
                return Filter{
                    .driver = try std.fmt.parseUnsigned(u32, filter[1..], 0),
                };
            }
        } else if (filter.len > 4 and std.ascii.eqlIgnoreCase(filter[0..4], "axis")) {
            return Filter{
                .axis = try std.fmt.parseUnsigned(u32, filter[4..], 0),
            };
        } else if (filter.len > 6 and std.ascii.eqlIgnoreCase(filter[0..6], "driver")) {
            return Filter{
                .driver = try std.fmt.parseUnsigned(u32, filter[6..], 0),
            };
        } else if (filter.len > 7 and std.ascii.eqlIgnoreCase(filter[0..7], "carrier")) {
            return Filter{
                .carrier = [1]u32{try std.fmt.parseUnsigned(u32, filter[7..], 0)},
            };
        }
        return error.InvalidParameter;
    }

    pub fn toProtobuf(filter: *Filter) client.api.api.protobuf.mmc.info.Request.Track.filter_union {
        return switch (filter.*) {
            .axis => |axis_id| .{
                .axes = .{
                    .start = axis_id,
                    .end = axis_id,
                },
            },
            .driver => |driver_id| .{
                .drivers = .{
                    .start = driver_id,
                    .end = driver_id,
                },
            },
            .carrier => .{
                .carriers = .{ .ids = .fromOwnedSlice(&filter.carrier) },
            },
        };
    }
};

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

pub fn setSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 6.0) return error.InvalidSpeed;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].velocity = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(client.lines[line_idx].velocity)) / 10.0,
    });
}

pub fn setAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 24.5)
        return error.InvalidAcceleration;

    const line_idx = try client.matchLine(line_name);
    client.lines[line_idx].acceleration = @intFromFloat(carrier_acceleration * 10.0);

    std.log.info("Set acceleration to {d}m/s^2.", .{
        @as(f32, @floatFromInt(client.lines[line_idx].acceleration)) / 10.0,
    });
}

pub fn getSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try client.matchLine(line_name);
    std.log.info(
        "Line {s} speed: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(client.lines[line_idx].velocity)) / 10.0,
        },
    );
}

pub fn getAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try client.matchLine(line_name);
    std.log.info(
        "Line {s} acceleration: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(client.lines[line_idx].acceleration)) / 10.0,
        },
    );
}

pub fn serverVersion(_: [][]const u8) !void {
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

pub fn showError(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_axis_errors = true,
                .info_driver_errors = true,
                .filter = if (filter) |*_filter|
                    _filter.toProtobuf()
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const axis_errors = track.axis_errors;
    const driver_errors = track.driver_errors;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (axis_errors.items) |err| {
        try client.api.response.info.track.axis.err.printActive(
            err,
            writer,
        );
    }
    for (driver_errors.items) |err| {
        try client.api.response.info.track.driver.err.printActive(
            err,
            writer,
        );
    }
}

pub fn axisInfo(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_axis_errors = true,
                .info_axis_state = true,
                .filter = filter.toProtobuf(),
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const axis_state = track.axis_state;
    const axis_errors = track.axis_errors;
    if (axis_state.items.len != axis_errors.items.len)
        return error.InvalidResponse;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (axis_state.items, axis_errors.items) |info, err| {
        try client.api.response.info.track.axis.state.print(info, writer);
        try client.api.response.info.track.axis.err.print(err, writer);
    }
}

pub fn driverInfo(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_driver_state = true,
                .info_driver_errors = true,
                .filter = filter.toProtobuf(),
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const driver_state = track.driver_state;
    const driver_errors = track.driver_errors;
    if (driver_state.items.len != driver_errors.items.len)
        return error.InvalidResponse;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (driver_state.items, driver_errors.items) |info, err| {
        try client.api.response.info.track.driver.state.print(info, writer);
        try client.api.response.info.track.driver.err.print(err, writer);
    }
}

pub fn carrierInfo(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = filter.toProtobuf(),
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const carriers = track.carrier_state;
    if (carriers.items.len == 0) return error.CarrierNotFound;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    for (carriers.items) |carrier| {
        try client.api.response.info.track.carrier.print(carrier, writer);
    }
}

pub fn autoInitialize(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var init_lines: std.ArrayList(
        client.api.api.protobuf.mmc.command.Request.AutoInitialize.Line,
    ) = .empty;
    defer init_lines.deinit(client.allocator);
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try client.matchLine(line_name);
            const _line = client.lines[line_idx];
            const line: client.api.api.protobuf.mmc.command.Request.AutoInitialize.Line = .{
                .line = _line.id,
            };
            try init_lines.append(client.allocator, line);
        }
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.auto_initialize.encode(
            client.allocator,
            &writer.interface,
            .{ .lines = init_lines },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn axisCarrier(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const result_var: []const u8 = params[2];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .axes = .{
                        .start = axis_id,
                        .end = axis_id,
                    },
                },
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    var carriers = track.carrier_state;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    std.log.info("Carrier {d} on axis {d}.\n", .{ carrier.id, axis_id });
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
        );
    }
}

pub fn carrierId(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var line_name_iterator = std.mem.tokenizeSequence(
        u8,
        params[0],
        ",",
    );
    const result_var: []const u8 = params[1];
    if (result_var.len > 32) return error.PrefixTooLong;

    // Validate line names, avoid heap allocation
    var line_counter: usize = 0;
    while (line_name_iterator.next()) |line_name| {
        if (client.matchLine(line_name)) |_| {
            line_counter += 1;
        } else |e| {
            std.log.info("Line {s} not found", .{line_name});
            return e;
        }
    }

    var line_idxs: std.ArrayList(usize) = .empty;
    defer line_idxs.deinit(client.allocator);
    line_name_iterator.reset();
    while (line_name_iterator.next()) |line_name| {
        try line_idxs.append(client.allocator, try client.matchLine(line_name));
    }

    var count: usize = 1;
    for (line_idxs.items) |line_idx| {
        const line = client.lines[line_idx];
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = null,
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        const axis_state = track.axis_state;
        if (axis_state.items.len != line.axes) return error.InvalidResponse;
        var last_carrier: u32 = 0;
        for (axis_state.items) |axis| {
            if (axis.carrier == 0 or last_carrier == axis.carrier) continue;
            std.log.info(
                "Carrier {d} on line {s} axis {d}",
                .{ axis.carrier, line.name, axis.id },
            );
            if (result_var.len > 0) {
                var int_buf: [8]u8 = undefined;
                var var_buf: [40]u8 = undefined;
                const key = try std.fmt.bufPrint(
                    &var_buf,
                    "{s}_{d}",
                    .{ result_var, count },
                );
                const value = try std.fmt.bufPrint(
                    &int_buf,
                    "{d}",
                    .{axis.carrier},
                );
                try command.variables.put(key, value);
                count += 1;
            }
            last_carrier = axis.carrier;
        }
    }
}

pub fn assertLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const expected_location: f32 = try std.fmt.parseFloat(f32, params[2]);
    // Default location threshold value is 1 mm
    const location_thr = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        1.0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(client.allocator);
        try ids.append(client.allocator, carrier_id);
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    var carriers = track.carrier_state;
    if (track.line != line.id) return error.InvalidResponse;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    const location = carrier.position;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
}

pub fn releaseCarrier(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const carrier_id: ?u32 = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => {
                {
                    try client.removeIgnoredMessage(socket);
                    try socket.waitToWrite(&command.checkCommandInterrupt);
                    var writer = socket.writer(&client.writer_buf);
                    try client.api.request.info.track.encode(
                        client.allocator,
                        &writer.interface,
                        .{
                            .line = line.id,
                            .info_axis_state = true,
                            .filter = _filter.toProtobuf(),
                        },
                    );
                    try writer.interface.flush();
                }
                try socket.waitToRead(&command.checkCommandInterrupt);
                var reader = socket.reader(&client.reader_buf);
                var track = try client.api.response.info.track.decode(
                    client.allocator,
                    &reader.interface,
                );
                defer track.deinit(client.allocator);
                if (track.line != line.id) return error.InvalidResponse;
                const axis = track.axis_state.pop() orelse return error.InvalidResponse;
                if (axis.carrier == 0) return error.CarrierNotFound;
                break :b axis.carrier;
            },
            .driver => return error.InvalidParameter,
            .carrier => |carrier_id| break :b carrier_id[0],
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.release.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = if (carrier_id) |carrier| carrier else null,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn clearErrors(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const driver_id: ?u32 = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b axis / 3,
            .driver => |driver| break :b driver,
            .carrier => {
                {
                    try client.removeIgnoredMessage(socket);
                    try socket.waitToWrite(&command.checkCommandInterrupt);
                    var writer = socket.writer(&client.writer_buf);
                    try client.api.request.info.track.encode(
                        client.allocator,
                        &writer.interface,
                        .{
                            .line = line.id,
                            .info_carrier_state = true,
                            .filter = _filter.toProtobuf(),
                        },
                    );
                    try writer.interface.flush();
                }
                try socket.waitToRead(&command.checkCommandInterrupt);
                var reader = socket.reader(&client.reader_buf);
                var track = try client.api.response.info.track.decode(
                    client.allocator,
                    &reader.interface,
                );
                defer track.deinit(client.allocator);
                if (track.line != line.id) return error.InvalidResponse;
                var carriers = track.carrier_state;
                if (carriers.items.len > 1) return error.InvalidResponse;
                const carrier = carriers.pop() orelse return error.CarrierNotFound;
                break :b carrier.axis_main / 3;
            },
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.clear_errors.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .drivers = if (driver_id) |id|
                    .{ .start = id, .end = id }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn clearCarrierInfo(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const axis_id: ?struct { start: u32, end: u32 } = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b .{ .start = axis, .end = axis },
            .driver => |driver| {
                const start = (driver - 1) * 3 + 1;
                const end = (driver - 1) * 3 + 3;
                break :b .{ .start = start, .end = end };
            },
            .carrier => {
                {
                    try client.removeIgnoredMessage(socket);
                    try socket.waitToWrite(&command.checkCommandInterrupt);
                    var writer = socket.writer(&client.writer_buf);
                    try client.api.request.info.track.encode(
                        client.allocator,
                        &writer.interface,
                        .{
                            .line = line.id,
                            .info_carrier_state = true,
                            .filter = _filter.toProtobuf(),
                        },
                    );
                    try writer.interface.flush();
                }
                try socket.waitToRead(&command.checkCommandInterrupt);
                var reader = socket.reader(&client.reader_buf);
                var track = try client.api.response.info.track.decode(
                    client.allocator,
                    &reader.interface,
                );
                defer track.deinit(client.allocator);
                if (track.line != line.id) return error.InvalidResponse;
                var carriers = track.carrier_state;
                if (carriers.items.len > 1) return error.InvalidResponse;
                const carrier = carriers.pop() orelse return error.CarrierNotFound;
                break :b .{ .start = carrier.axis_main, .end = carrier.axis_main };
            },
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.deinitialize.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axes = if (axis_id) |id|
                    .{ .start = id.start, .end = id.end }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn resetSystem(_: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    for (client.lines) |line| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.deinitialize.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.clear_errors.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.stop_push.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.stop_pull.encode(
                client.allocator,
                &writer.interface,
                .{ .line = line.id },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
    }
}

pub fn carrierLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(client.allocator);
        try ids.append(client.allocator, carrier_id);
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    var carriers = track.carrier_state;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    std.log.info(
        "Carrier {d} location: {d} mm",
        .{ carrier.id, carrier.position },
    );
    if (result_var.len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(result_var, try std.fmt.bufPrint(
            &float_buf,
            "{d}",
            .{carrier.position},
        ));
    }
}

pub fn carrierAxis(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(client.allocator);
        try ids.append(client.allocator, carrier_id);
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    var carriers = track.carrier_state;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    std.log.info(
        "Carrier {d} axis: {}",
        .{ carrier.id, carrier.axis_main },
    );
    if (carrier.axis_auxiliary) |aux|
        std.log.info(
            "Carrier {d} axis: {}",
            .{ carrier.id, aux },
        );
}

pub fn hallStatus(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: ?Filter = null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    if (filter) |*_filter| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = _filter.toProtobuf(),
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        for (track.axis_state.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm_back) "ON" else "OFF",
                    if (axis.hall_alarm_front) "ON" else "OFF",
                },
            );
        }
    } else {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = null,
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id and
            track.axis_state.items.len != line.axes)
            return error.InvalidResponse;
        // Starts printing hall status
        for (track.axis_state.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm_back) "ON" else "OFF",
                    if (axis.hall_alarm_front) "ON" else "OFF",
                },
            );
        }
    }
}

pub fn assertHall(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const side: client.api.api.protobuf.mmc.command.Request.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .DIRECTION_BACKWARD
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .DIRECTION_FORWARD
        else
            return error.InvalidHallAlarmSide;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];

    var alarm_on: bool = true;
    if (params[3].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[3])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[3])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_axis_state = true,
                .filter = .{
                    .axes = .{
                        .start = axis_id,
                        .end = axis_id,
                    },
                },
            },
        );
        try writer.interface.flush();
    }
    try socket.waitToRead(&command.checkCommandInterrupt);
    var reader = socket.reader(&client.reader_buf);
    var track = try client.api.response.info.track.decode(
        client.allocator,
        &reader.interface,
    );
    defer track.deinit(client.allocator);
    if (track.line != line.id) return error.InvalidResponse;
    const axis = track.axis_state.pop() orelse return error.InvalidResponse;
    switch (side) {
        .DIRECTION_BACKWARD => {
            if (axis.hall_alarm_back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .DIRECTION_FORWARD => {
            if (axis.hall_alarm_front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        else => return error.UnexpectedResponse,
    }
}

pub fn calibrate(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.calibrate.encode(
            client.allocator,
            &writer.interface,
            .{ .line = line.id },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn setLineZero(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.set_zero.encode(
            client.allocator,
            &writer.interface,
            .{ .line = line.id },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn isolate(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];

    const dir: client.api.api.protobuf.mmc.command.Request.Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .DIRECTION_FORWARD;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .DIRECTION_BACKWARD;
        } else {
            return error.InvalidDirection;
        }
    };

    const carrier_id: u10 = if (params[3].len > 0)
        try std.fmt.parseInt(u10, params[3], 0)
    else
        0;
    const link_axis: ?client.api.api.protobuf.mmc.command.Request.Direction = link: {
        if (params[4].len > 0) {
            if (std.ascii.eqlIgnoreCase("next", params[4]) or
                std.ascii.eqlIgnoreCase("right", params[4]))
            {
                break :link .DIRECTION_FORWARD;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .DIRECTION_BACKWARD;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link null;
    };
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.initialize.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axis = axis_id,
                .carrier = carrier_id,
                .link_axis = link_axis,
                .direction = dir,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn waitIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try client.carrier.waitState(
        client.allocator,
        line.id,
        carrier_id,
        .CARRIER_STATE_INITIALIZE_COMPLETED,
        timeout,
    );
}

pub fn waitMoveCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try client.carrier.waitState(
        client.allocator,
        line.id,
        carrier_id,
        .CARRIER_STATE_MOVE_COMPLETED,
        timeout,
    );
}

pub fn carrierPosMoveAxis(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(
        u32,
        params[2],
        0,
    );
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPosMoveLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPosMoveDistance(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control = .CONTROL_POSITION,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveAxis(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(u32, params[2], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveLocation(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveDistance(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.move.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control = .CONTROL_VELOCITY,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPushForward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?u32 = if (params[2].len > 0)
        try std.fmt.parseInt(u32, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.move.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .target = .{
                        .location = line.length.axis * @as(
                            f32,
                            @floatFromInt(axis - 1),
                        ) + 0.15,
                        // 0.15: offset for continuous push (m)
                    },
                    .disable_cas = true,
                    .control = .CONTROL_POSITION,
                },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        {
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.push.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .direction = .DIRECTION_FORWARD,
                    .axis = axis,
                },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        return;
    }
    // Get the axis information
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        var ids: [1]u32 = .{carrier_id};
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                },
            },
        );
        try writer.interface.flush();
    }
    const carrier = carrier: {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        var carrier_state = track.carrier_state;
        break :carrier carrier_state.pop() orelse return error.CarrierNotFound;
    };
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.push.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier.id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_FORWARD,
                .axis = carrier.axis_main,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPushBackward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?u32 = if (params[2].len > 0)
        try std.fmt.parseInt(u32, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.move.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .target = .{
                        .location = line.length.axis * @as(
                            f32,
                            @floatFromInt(axis - 1),
                        ) - 0.15,
                        // 0.15: offset for continuous push
                    },
                    .disable_cas = true,
                    .control = .CONTROL_POSITION,
                },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        {
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.push.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .carrier = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .direction = .DIRECTION_BACKWARD,
                    .axis = axis,
                },
            );
            try writer.interface.flush();
        }
        try waitCommandReceived(client.allocator);
        return;
    }
    // Get the axis information
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        var ids: [1]u32 = .{carrier_id};
        try client.api.request.info.track.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .info_carrier_state = true,
                .filter = .{
                    .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                },
            },
        );
        try writer.interface.flush();
    }
    const carrier = carrier: {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        var carrier_state = track.carrier_state;
        break :carrier carrier_state.pop() orelse return error.CarrierNotFound;
    };
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.push.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier.id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .axis = carrier.axis_main,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPullForward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pull.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axis = axis_id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_FORWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPullBackward(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pull.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axis = axis_id,
                .carrier = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierWaitPull(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try client.carrier.waitState(
        client.allocator,
        line.id,
        carrier_id,
        .CARRIER_STATE_PULL_COMPLETED,
        timeout,
    );
}

pub fn carrierStopPull(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const axis_id: ?struct { start: u32, end: u32 } = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b .{ .start = axis, .end = axis },
            .driver => |driver| break :b .{
                .start = driver * 3 - 2,
                .end = driver * 3,
            },
            .carrier => return error.InvalidParameter,
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.stop_pull.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axes = if (axis_id) |id|
                    .{ .start = id.start, .end = id.end }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierStopPush(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const axis_id: ?struct { start: u32, end: u32 } = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => |axis| break :b .{ .start = axis, .end = axis },
            .driver => |driver| break :b .{
                .start = driver * 3 - 2,
                .end = driver * 3,
            },
            .carrier => return error.InvalidParameter,
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.stop_push.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .axes = if (axis_id) |id|
                    .{ .start = id.start, .end = id.end }
                else
                    null,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn setCarrierId(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier = try std.fmt.parseInt(u32, params[1], 0);
    const new_carrier = try std.fmt.parseInt(u32, params[2], 0);
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.set_carrier_id.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = carrier,
                .new_carrier = new_carrier,
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn waitAxisEmpty(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(u32, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = .{
                        .axes = .{
                            .start = axis_id,
                            .end = axis_id,
                        },
                    },
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        const axis = track.axis_state.pop() orelse return error.InvalidResponse;
        if (axis.carrier == 0 and
            !axis.hall_alarm_back and
            !axis.hall_alarm_front and
            !axis.waiting_push and
            !axis.waiting_pull)
        {
            break;
        }
    }
}

pub fn addLogInfo(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const kind = params[1];
    if (kind.len == 0) return error.MissingParameter;
    const line = client.lines[line_idx];
    const range = params[2];
    var log_range: client.Log.Config.Range = undefined;
    if (range.len > 0) {
        var range_iterator = std.mem.tokenizeSequence(u8, range, ":");
        log_range = .{
            .start = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
            .end = try std.fmt.parseInt(
                u32,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
        };
    } else {
        log_range = .{ .start = 1, .end = line.axes };
    }
    if ((log_range.start < 1 and
        log_range.start > line.axes) or
        (log_range.end < 1 and
            log_range.end > line.axes))
        return error.InvalidAxis;
    if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("axis", kind) or
        std.ascii.eqlIgnoreCase("driver", kind))
    {} else return error.InvalidKind;
    client.log.configs[line_idx].axis =
        if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("axis", kind))
            true
        else
            false;
    client.log.configs[line_idx].driver =
        if (std.ascii.eqlIgnoreCase("all", kind) or
        std.ascii.eqlIgnoreCase("driver", kind))
            true
        else
            false;
    client.log.configs[line_idx].axis_id_range = log_range;
    try client.log.status();
}

pub fn startLogInfo(params: [][]const u8) !void {
    errdefer client.log.reset();
    const duration = try std.fmt.parseFloat(f64, params[0]);
    const path = params[1];
    client.log.path = if (path.len > 0) path else p: {
        var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(timestamp / std.time.s_per_day);
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(timestamp % std.time.s_per_day);
        const time = try chrono.Time.fromNumSecondsFromMidnight(
            time_day,
            0,
        );
        break :p try std.fmt.allocPrint(
            client.allocator,
            "mmc-logging-{}.{:0>2}.{:0>2}-{:0>2}.{:0>2}.{:0>2}.csv",
            .{
                ymd.year,
                ymd.month.number(),
                ymd.day,
                time.hour(),
                time.minute(),
                time.second(),
            },
        );
    };
    const log_thread = try std.Thread.spawn(
        .{},
        client.Log.handler,
        .{duration},
    );
    log_thread.detach();
}

pub fn statusLogInfo(_: [][]const u8) !void {
    try client.log.status();
}

pub fn removeLogInfo(params: [][]const u8) !void {
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        client.log.configs[line_idx].deinit(client.log.allocator);
    } else {
        for (client.log.configs) |*config| {
            config.deinit(client.log.allocator);
        }
    }
    try client.log.status();
}

pub fn stopLine(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids: [1]u32 = .{0};
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        ids[0] = @intCast(line_idx + 1);
    }
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.stop.encode(
            client.allocator,
            &writer.interface,
            .{
                .lines = .fromOwnedSlice(if (ids[0] > 0) &ids else &.{}),
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn pauseLine(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids: [1]u32 = .{0};
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        ids[0] = @intCast(line_idx + 1);
    }
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.pause.encode(
            client.allocator,
            &writer.interface,
            .{
                .lines = .fromOwnedSlice(if (ids[0] > 0) &ids else &.{}),
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

pub fn resumeLine(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var ids: [1]u32 = .{0};
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try client.matchLine(line_name);
        ids[0] = @intCast(line_idx + 1);
    }
    {
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.@"resume".encode(
            client.allocator,
            &writer.interface,
            .{
                .lines = .fromOwnedSlice(if (ids[0] > 0) &ids else &.{}),
            },
        );
        try writer.interface.flush();
    }
    try waitCommandReceived(client.allocator);
}

fn waitCommandReceived(allocator: std.mem.Allocator) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    var id: u32 = 0;
    {
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        id = try client.api.response.command.id.decode(
            client.allocator,
            &reader.interface,
        );
    }
    defer client.removeCommand(allocator, id) catch {};
    while (true) {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.command.encode(
                allocator,
                &writer.interface,
                .{
                    .id = id,
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var decoded = try client.api.response.info.command.decode(
            allocator,
            &reader.interface,
        );
        defer decoded.deinit(client.allocator);
        if (decoded.items.items.len > 1) return error.InvalidResponse;
        if (decoded.items.pop()) |comm| {
            std.log.debug("{}", .{comm});
            switch (comm.status) {
                .COMMAND_STATUS_PROGRESSING => {}, // continue the loop
                .COMMAND_STATUS_COMPLETED => break,
                .COMMAND_STATUS_FAILED => {
                    return switch (comm.@"error".?) {
                        .COMMAND_ERROR_INVALID_SYSTEM_STATE => error.InvalidSystemState,
                        .COMMAND_ERROR_DRIVER_DISCONNECTED => error.DriverDisconnected,
                        .COMMAND_ERROR_UNEXPECTED => error.Unexpected,
                        .COMMAND_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                        .COMMAND_ERROR_CONFLICTING_CARRIER_ID => error.ConflictingCarrierId,
                        .COMMAND_ERROR_CARRIER_ALREADY_INITIALIZED => error.CarrierAlreadyInitialized,
                        .COMMAND_ERROR_INVALID_CARRIER_TARGET => error.InvalidCarrierTarget,
                        .COMMAND_ERROR_DRIVER_STOPPED => error.DriverStopped,
                        else => error.UnexpectedResponse,
                    };
                },
                else => return error.UnexpectedResponse,
            }
        } else return error.InvalidResponse;
    }
}
