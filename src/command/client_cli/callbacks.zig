const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");
const api = @import("api.zig");
const client = @import("../client_cli.zig");
const command = @import("../../command.zig");

pub fn connect(params: [][]const u8) !void {
    if (client.net.socket) |_| {
        if (client.net.isSocketEventOccurred(
            std.posix.POLL.IN | std.posix.POLL.OUT,
            0,
        )) |socket_status| {
            if (socket_status)
                return error.ConnectionIsAlreadyEstablished
            else
                try client.disconnect();
        } else |e| {
            std.log.err("{t}", .{e});
            try client.disconnect();
        }
    }
    var endpoint: client.Network.Endpoint = undefined;
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(u8, params[0], ":");
        endpoint.ip = @constCast(iterator.next() orelse return error.MissingParameter);
        if (endpoint.ip.len > 63) return error.InvalidIPAddress;
        endpoint.port = try std.fmt.parseInt(
            u16,
            iterator.next() orelse return error.MissingParameter,
            0,
        );
    } else {
        endpoint = client.net.endpoint;
    }
    std.log.info(
        "Trying to connect to {s}:{d}",
        .{ endpoint.ip, endpoint.port },
    );
    try client.net.connect(
        client.allocator,
        endpoint,
    );
    errdefer client.net.close() catch {};
    std.log.info(
        "Connected to {f}",
        .{try client.net.socket.?.getRemoteEndPoint()},
    );
    // Asserting that API version matched between client and server
    {
        // Send API version request
        const msg = try api.request.core.encode(
            client.allocator,
            .CORE_REQUEST_KIND_API_VERSION,
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    {
        const msg = try client.net.receive(client.allocator);
        defer client.allocator.free(msg);
        const response = try api.response.core.api_version.decode(
            client.allocator,
            msg,
        );
        if (api.api.version.major != response.major or
            api.api.version.minor != response.minor)
        {
            return error.APIVersionMismatch;
        }
    }
    // Get line configuration
    {
        // Send line configuration request
        const msg = try api.request.core.encode(
            client.allocator,
            .CORE_REQUEST_KIND_LINE_CONFIG,
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    {
        const msg = try client.net.receive(client.allocator);
        defer client.allocator.free(msg);
        const response = try api.response.core.line_config.decode(
            client.allocator,
            msg,
        );
        defer response.deinit();
        client.lines = try client.allocator.alloc(
            client.Line,
            response.lines.items.len,
        );
        for (
            response.lines.items,
            client.lines,
            0..,
        ) |config, *line, idx| {
            try line.init(client.allocator, @intCast(idx), config);
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
    // Initialize memory for logging configuration
    client.log = try client.Log.init(
        client.allocator,
        client.lines,
        client.net.endpoint,
    );
    for (client.log.configs, client.lines) |*config, line| {
        try config.init(client.allocator, line.id, line.name);
    }
}

/// Serve as a callback of a `DISCONNECT` command, requires parameter.
pub fn disconnect(_: [][]const u8) error{ServerNotConnected}!void {
    try client.disconnect();
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
    {
        const msg = try api.request.core.encode(
            client.allocator,
            .CORE_REQUEST_KIND_SERVER_INFO,
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const server = try api.response.core.server.decode(
        client.allocator,
        msg,
    );
    defer server.deinit();
    const version = server.version.?;
    const name = server.name.getSlice();
    std.log.info(
        "{s} server version: {d}.{d}.{d}\n",
        .{ name, version.major, version.minor, version.patch },
    );
}

pub fn showError(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const source: ?api.api.info_msg.Range = b: {
        if (params[1].len > 0) {
            const axis_id = try std.fmt.parseInt(
                client.Axis.Id.Line,
                params[1],
                0,
            );
            if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
            break :b .{ .start_id = axis_id, .end_id = axis_id };
        } else break :b null;
    };
    {
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .axis = true,
                .driver = true,
                .source = if (source) |range|
                    .{ .axis_range = range }
                else
                    null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    var axis_errors = system.axis_errors;
    var driver_errors = system.driver_errors;
    if (source) |_| {
        if (axis_errors.items.len != 1) return error.InvalidResponse;
        if (driver_errors.items.len != 1) return error.InvalidResponse;
    } else {
        if (axis_errors.items.len != line.axes.len) return error.InvalidResponse;
        if (driver_errors.items.len != line.drivers.len)
            return error.InvalidResponse;
    }
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    if (source) |_| {
        try api.response.info.system.axis.err.printActive(
            axis_errors.pop().?,
            writer,
        );
        try api.response.info.system.driver.err.printActive(
            driver_errors.pop().?,
            writer,
        );
        return;
    }
    for (axis_errors.items) |err| {
        try api.response.info.system.axis.err.printActive(
            err,
            writer,
        );
    }
    for (driver_errors.items) |err| {
        try api.response.info.system.driver.err.printActive(
            err,
            writer,
        );
    }
}

pub fn axisInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    {
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = .{
                    .axis_range = .{
                        .start_id = @intCast(axis_id),
                        .end_id = @intCast(axis_id),
                    },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    var axis_infos = system.axis_infos;
    var axis_errors = system.axis_errors;
    if (axis_infos.items.len != axis_errors.items.len and
        axis_infos.items.len != 1)
        return error.InvalidResponse;
    const info = axis_infos.pop().?;
    const err = axis_errors.pop().?;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    try api.response.info.system.axis.info.print(info, writer);
    try api.response.info.system.axis.err.print(err, writer);
}

pub fn driverInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const driver_id = try std.fmt.parseInt(client.Driver.Id, params[1], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (driver_id < 1 or driver_id > line.drivers.len) return error.InvalidDriver;
    {
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .driver = true,
                .source = .{
                    .driver_range = .{
                        .start_id = @intCast(driver_id),
                        .end_id = @intCast(driver_id),
                    },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    var driver_infos = system.driver_infos;
    var driver_errors = system.driver_errors;
    if (driver_infos.items.len != driver_errors.items.len and
        driver_errors.items.len != 1)
        return error.InvalidResponse;
    const info = driver_infos.pop().?;
    const err = driver_errors.pop().?;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    try api.response.info.system.driver.info.print(info, writer);
    try api.response.info.system.driver.err.print(err, writer);
}

pub fn carrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids = std.ArrayListAligned(u32, null).init(client.allocator);
        defer ids.deinit();
        try ids.append(carrier_id);
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    var carriers = system.carrier_infos;
    if (carriers.items.len > 1) return error.InvalidResponse;
    const carrier = carriers.pop() orelse return error.CarrierNotFound;
    var stdout = std.fs.File.stdout().writer(&.{});
    const writer = &stdout.interface;
    try api.response.info.system.carrier.print(carrier, writer);
}

pub fn autoInitialize(params: [][]const u8) !void {
    var init_lines = std.ArrayListAligned(
        api.api.command_msg.Request.AutoInitialize.Line,
        null,
    ).init(client.allocator);
    defer init_lines.deinit();
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try client.matchLine(line_name);
            const _line = client.lines[line_idx];
            const line: api.api.command_msg.Request.AutoInitialize.Line = .{
                .line_id = _line.id,
            };
            try init_lines.append(line);
        }
    } else {
        for (client.lines) |_line| {
            const line: api.api.command_msg.Request.AutoInitialize.Line = .{
                .line_id = @intCast(_line.id),
            };
            try init_lines.append(line);
        }
    }
    {
        const msg = try api.request.command.auto_initialize.encode(
            client.allocator,
            .{ .lines = init_lines },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn axisCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const result_var: []const u8 = params[2];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    {
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{
                    .axis_range = .{
                        .start_id = @intCast(axis_id),
                        .end_id = @intCast(axis_id),
                    },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    if (system.line_id != line.id) return error.InvalidResponse;
    var carriers = system.carrier_infos;
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

pub fn carrierID(params: [][]const u8) !void {
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

    var line_idxs =
        std.ArrayList(usize).init(client.allocator);
    defer line_idxs.deinit();
    line_name_iterator.reset();
    while (line_name_iterator.next()) |line_name| {
        try line_idxs.append(@intCast(try client.matchLine(line_name)));
    }

    var variable_count: usize = 1;
    for (line_idxs.items) |line_idx| {
        const line = client.lines[line_idx];
        {
            const msg = try api.request.info.system.encode(
                client.allocator,
                .{
                    .line_id = @intCast(line.id),
                    .axis = true,
                    .source = null,
                },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        const msg = try client.net.receive(client.allocator);
        defer client.allocator.free(msg);
        const system = try api.response.info.system.decode(
            client.allocator,
            msg,
        );
        defer system.deinit();
        const axis_infos = system.axis_infos;
        if (axis_infos.items.len != line.axes.len)
            return error.InvalidResponse;
        for (axis_infos.items) |axis| {
            if (axis.carrier_id == 0) continue;
            std.log.info(
                "Carrier {d} on line {s} axis {d}",
                .{ axis.carrier_id, line.name, axis.id },
            );
            if (result_var.len > 0) {
                var int_buf: [8]u8 = undefined;
                var var_buf: [36]u8 = undefined;
                const variable_key = try std.fmt.bufPrint(
                    &var_buf,
                    "{s}_{d}",
                    .{ result_var, variable_count },
                );
                const variable_value = try std.fmt.bufPrint(
                    &int_buf,
                    "{d}",
                    .{axis.carrier_id},
                );
                var iterator = command.variables.iterator();
                var isValueExists: bool = false;
                while (iterator.next()) |entry| {
                    if (std.mem.eql(u8, variable_value, entry.value_ptr.*)) {
                        isValueExists = true;
                        break;
                    }
                }
                if (!isValueExists) {
                    try command.variables.put(
                        variable_key,
                        variable_value,
                    );
                    variable_count += 1;
                }
            }
        }
    }
}

pub fn assertLocation(params: [][]const u8) !void {
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
        var ids = std.ArrayListAligned(u32, null).init(client.allocator);
        defer ids.deinit();
        try ids.append(carrier_id);
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    var carriers = system.carrier_infos;
    if (system.line_id != line.id) return error.InvalidResponse;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    const location = carrier.position;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
}

pub fn releaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var axis_id: ?client.Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(
            client.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    {
        const msg = try api.request.command.release_control.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .axis_id = if (axis_id) |axis| @intCast(axis) else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn clearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var axis_id: ?client.Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    {
        const msg = try api.request.command.clear_errors.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .driver_id = if (axis_id) |id|
                    @intCast(line.axes[id - 1].driver.id)
                else
                    null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn clearCarrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var axis_id: ?client.Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    {
        const msg = try api.request.command.clear_carriers.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .axis_id = if (axis_id) |id| @intCast(id) else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn resetSystem(_: [][]const u8) !void {
    for (client.lines) |line| {
        {
            const msg = try api.request.command.clear_carriers.encode(
                client.allocator,
                .{ .line_id = line.id },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
        {
            const msg = try api.request.command.clear_errors.encode(
                client.allocator,
                .{ .line_id = line.id },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
        {
            const msg = try api.request.command.stop_push_carrier.encode(
                client.allocator,
                .{ .line_id = line.id },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
        {
            const msg = try api.request.command.stop_pull_carrier.encode(
                client.allocator,
                .{ .line_id = line.id },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
    }
}

pub fn carrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids = std.ArrayListAligned(u32, null).init(client.allocator);
        defer ids.deinit();
        try ids.append(carrier_id);
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    if (system.line_id != line.id) return error.InvalidResponse;
    var carriers = system.carrier_infos;
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
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        var ids = std.ArrayListAligned(u32, null).init(client.allocator);
        defer ids.deinit();
        try ids.append(carrier_id);
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{
                    .carriers = .{ .ids = ids },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    const system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    if (system.line_id != line.id) return error.InvalidResponse;
    var carriers = system.carrier_infos;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    if (carrier.axis) |axis| {
        std.log.info(
            "Carrier {d} axis: {}",
            .{ carrier.id, axis.main },
        );
        if (axis.auxiliary) |aux|
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, aux },
            );
    } else return error.InvalidResponse;
}

pub fn hallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    var axis_id: ?client.Axis.Id.Line = null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    if (axis_id) |id| {
        {
            const msg = try api.request.info.system.encode(
                client.allocator,
                .{
                    .line_id = @intCast(line.id),
                    .axis = true,
                    .source = .{
                        .axis_range = .{
                            .start_id = @intCast(id),
                            .end_id = @intCast(id),
                        },
                    },
                },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        const msg = try client.net.receive(client.allocator);
        defer client.allocator.free(msg);
        var system = try api.response.info.system.decode(
            client.allocator,
            msg,
        );
        defer system.deinit();
        if (system.line_id != line.id) return error.InvalidResponse;
        const axis = system.axis_infos.pop() orelse return error.InvalidResponse;
        const hall = axis.hall_alarm orelse return error.InvalidResponse;
        std.log.info(
            "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
            .{
                axis.id,
                if (hall.back) "ON" else "OFF",
                if (hall.front) "ON" else "OFF",
            },
        );
    } else {
        {
            const msg = try api.request.info.system.encode(
                client.allocator,
                .{
                    .line_id = @intCast(line.id),
                    .axis = true,
                    .source = null,
                },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        const msg = try client.net.receive(client.allocator);
        defer client.allocator.free(msg);
        const system = try api.response.info.system.decode(
            client.allocator,
            msg,
        );
        defer system.deinit();
        if (system.line_id != line.id and
            system.axis_infos.items.len != line.axes.len)
            return error.InvalidResponse;
        // Starts printing hall status
        for (system.axis_infos.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm.?.back) "ON" else "OFF",
                    if (axis.hall_alarm.?.front) "ON" else "OFF",
                },
            );
        }
    }
}

pub fn assertHall(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const side: api.api.command_msg.Direction =
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
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    var alarm_on: bool = true;
    if (params[3].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[3])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[3])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }
    {
        const msg = try api.request.info.system.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = .{
                    .axis_range = .{
                        .start_id = @intCast(axis_id),
                        .end_id = @intCast(axis_id),
                    },
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    const msg = try client.net.receive(client.allocator);
    defer client.allocator.free(msg);
    var system = try api.response.info.system.decode(
        client.allocator,
        msg,
    );
    defer system.deinit();
    if (system.line_id != line.id) return error.InvalidResponse;
    const axis = system.axis_infos.pop() orelse return error.InvalidResponse;
    const hall = axis.hall_alarm.?;
    switch (side) {
        .DIRECTION_BACKWARD => {
            if (hall.back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .DIRECTION_FORWARD => {
            if (hall.front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        else => return error.UnexpectedResponse,
    }
}

pub fn calibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        const msg = try api.request.command.calibrate.encode(
            client.allocator,
            .{ .line_id = line.id },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn setLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    {
        const msg = try api.request.command.set_line_zero.encode(
            client.allocator,
            .{ .line_id = line.id },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn isolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    const dir: api.api.command_msg.Direction = dir_parse: {
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
    const link_axis: ?api.api.command_msg.Direction = link: {
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
        const msg = try api.request.command.isolate_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .axis_id = axis_id,
                .carrier_id = carrier_id,
                .link_axis = link_axis,
                .direction = dir,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
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
        .CARRIER_STATE_ISOLATE_COMPLETED,
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
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(
        client.Axis.Id.Line,
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
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_POSITION,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPosMoveLocation(params: [][]const u8) !void {
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
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_POSITION,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPosMoveDistance(params: [][]const u8) !void {
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
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_POSITION,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[2], 0);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .axis = axis_id },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_VELOCITY,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveLocation(params: [][]const u8) !void {
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
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .location = location },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_VELOCITY,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierSpdMoveDistance(params: [][]const u8) !void {
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
        const msg = try api.request.command.move_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .target = .{ .distance = distance },
                .disable_cas = disable_cas,
                .control_kind = .CONTROL_VELOCITY,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?client.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(client.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            const msg = try api.request.command.move_carrier.encode(
                client.allocator,
                .{
                    .line_id = line.id,
                    .carrier_id = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .target = .{
                        .location = line.length.axis * @as(
                            f32,
                            @floatFromInt(axis - 1),
                        ) + 150.0,
                    },
                    .disable_cas = true,
                    .control_kind = .CONTROL_POSITION,
                },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
    }
    {
        const msg = try api.request.command.push_carrier.encode(
            client.allocator,
            .{
                .line_id = @intCast(line.id),
                .carrier_id = carrier_id,
                .velocity = @intCast(client.lines[line_idx].velocity),
                .acceleration = @intCast(client.lines[line_idx].acceleration),
                .direction = .DIRECTION_FORWARD,
                .axis_id = if (axis_id) |axis| axis else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?client.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(client.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (axis_id) |axis| {
        {
            const msg = try api.request.command.move_carrier.encode(
                client.allocator,
                .{
                    .line_id = line.id,
                    .carrier_id = carrier_id,
                    .velocity = client.lines[line_idx].velocity,
                    .acceleration = client.lines[line_idx].acceleration,
                    .target = .{
                        .location = line.length.axis * @as(
                            f32,
                            @floatFromInt(axis - 1),
                        ) - 150.0,
                    },
                    .disable_cas = true,
                    .control_kind = .CONTROL_POSITION,
                },
            );
            defer client.allocator.free(msg);
            try client.net.send(msg);
        }
        try waitCommandReceived(client.allocator);
    }
    {
        const msg = try api.request.command.push_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .axis_id = if (axis_id) |axis| axis else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        const msg = try api.request.command.pull_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .axis_id = axis_id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_FORWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control_kind = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    {
        const msg = try api.request.command.pull_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .axis_id = axis_id,
                .carrier_id = carrier_id,
                .velocity = client.lines[line_idx].velocity,
                .acceleration = client.lines[line_idx].acceleration,
                .direction = .DIRECTION_BACKWARD,
                .transition = blk: {
                    if (destination) |loc| break :blk .{
                        .control_kind = .CONTROL_POSITION,
                        .disable_cas = disable_cas,
                        .target = .{
                            .location = loc,
                        },
                    } else break :blk null;
                },
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
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
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var axis_id: ?client.Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    {
        const msg = try api.request.command.stop_pull_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .axis_id = if (axis_id) |axis| axis else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
    try waitCommandReceived(client.allocator);
}

pub fn carrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var axis_id: ?client.Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    {
        const msg = try api.request.command.stop_push_carrier.encode(
            client.allocator,
            .{
                .line_id = line.id,
                .axis_id = if (axis_id) |axis| axis else null,
            },
        );
        defer client.allocator.free(msg);
        try client.net.send(msg);
    }
}

pub fn waitAxisEmpty(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(client.Axis.Id.Line, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    try client.Axis.waitEmpty(
        client.allocator,
        line.id,
        axis_id,
        timeout,
    );
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
                client.Axis.Id.Line,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
            .end = try std.fmt.parseInt(
                client.Axis.Id.Line,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
        };
    } else {
        log_range = .{ .start = 1, .end = @intCast(line.axes.len) };
    }
    if ((log_range.start < 1 and
        log_range.start > line.axes.len) or
        (log_range.end < 1 and
            log_range.end > line.axes.len))
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
            "mmc-register-{}.{:0>2}.{:0>2}-{:0>2}.{:0>2}.{:0>2}.csv",
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

fn waitCommandReceived(allocator: std.mem.Allocator) !void {
    var id: u32 = 0;
    {
        const msg = try client.net.receive(client.allocator);
        defer allocator.free(msg);
        id = try api.response.command.id.decode(
            client.allocator,
            msg,
        );
    }
    const msg = try api.request.info.commands.encode(
        allocator,
        .{
            .id = id,
        },
    );
    defer allocator.free(msg);
    while (true) {
        command.checkCommandInterrupt() catch |e| {
            try client.clearCommand(allocator, id);
            return e;
        };
        try client.net.send(msg);
        const resp = try client.net.receive(allocator);
        defer allocator.free(resp);
        var decoded = try api.response.info.commands.decode(
            allocator,
            resp,
        );
        defer decoded.deinit();
        if (decoded.commands.items.len > 1) return error.InvalidResponse;
        if (decoded.commands.pop()) |comm| {
            switch (comm.status) {
                .STATUS_PROGRESSING, .STATUS_QUEUED => {}, // continue the loop
                .STATUS_COMPLETED => break,
                .STATUS_FAILED => {
                    return switch (comm.error_response.?) {
                        .ERROR_KIND_CARRIER_ALREADY_EXISTS => error.CarrierAlreadyExists,
                        .ERROR_KIND_CARRIER_NOT_FOUND => error.CarrierNotFound,
                        .ERROR_KIND_HOMING_FAILED => error.HomingFailed,
                        .ERROR_KIND_INVALID_AXIS => error.InvalidAxis,
                        .ERROR_KIND_INVALID_COMMAND => error.InvalidCommand,
                        .ERROR_KIND_INVALID_PARAMETER => error.InvalidParameter,
                        .ERROR_KIND_INVALID_SYSTEM_STATE => error.InvalidSystemState,
                        else => error.UnexpectedResponse,
                    };
                },
                else => return error.UnexpectedResponse,
            }
        } else return error.InvalidResponse;
    }
}
