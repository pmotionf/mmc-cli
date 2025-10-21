//! This file contains callbacks for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const callbacks = @import("../callbacks.zig");
const command = @import("../../../command.zig");

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

pub fn releaseCarrier(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?callbacks.Filter = null;
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
            .carrier => |carrier_id| break :b carrier_id[0],
            .driver => {
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
                const carriers = track.carrier_state;
                if (carriers.items.len == 0) return error.CarrierNotFound;
                for (carriers.items) |carrier| {
                    {
                        try client.removeIgnoredMessage(socket);
                        try socket.waitToWrite(&command.checkCommandInterrupt);
                        var writer = socket.writer(&client.writer_buf);
                        try client.api.request.command.release.encode(
                            client.allocator,
                            &writer.interface,
                            .{
                                .line = line.id,
                                .carrier = carrier.id,
                            },
                        );
                        try writer.interface.flush();
                    }
                    try waitCommandReceived(client.allocator);
                }
                return;
            },
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
    var filter: ?callbacks.Filter = null;
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
    var filter: ?callbacks.Filter = null;
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
    var filter: ?callbacks.Filter = null;
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
    var filter: ?callbacks.Filter = null;
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

/// Get the command ID and track that command until completed.
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
    defer removeCommand(allocator, id) catch {};
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

fn removeCommand(a: std.mem.Allocator, id: u32) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    while (true) {
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.command.remove_commands.encode(
                a,
                &writer.interface,
                .{ .command = id },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        const removed_id = try client.api.response.command.removed_id.decode(
            a,
            &reader.interface,
        );
        std.log.debug("removed_id {}, id {}", .{ removed_id, id });
        if (removed_id == id) break;
    }
}
