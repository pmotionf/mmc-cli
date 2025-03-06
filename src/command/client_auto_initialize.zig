const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const mmc = @import("mmc_config");
const network = @import("network");
const CircularBuffer =
    @import("../circular_buffer.zig").CircularBuffer;

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u5 = undefined;
var line_accelerations: []u8 = undefined;
const Direction = mmc.Direction;
const Station = mmc.Station;
const SystemState = mmc.SystemState;

var IP_address: []u8 = undefined;
var port: u16 = undefined;

var server: ?network.Socket = null;

pub const Config = struct {
    IP_address: []u8,
    port: u16,
};

pub fn init(c: Config) !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    try network.init();
    IP_address = try allocator.alloc(u8, c.IP_address.len);
    @memcpy(IP_address, c.IP_address);
    port = c.port;
    std.log.debug("{s}, {}", .{
        IP_address,
        port,
    });
    try command.registry.put("CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file.
        ,
        .execute = &clientConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    try command.registry.put("DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End connection with the mmc server.
        ,
        .execute = &clientDisconnect,
    });
    errdefer _ = command.registry.orderedRemove("DISCONNECT");
}

pub fn deinit() void {
    arena.deinit();
    line_names = undefined;
    if (server) |s| {
        s.close();
    }
    network.deinit();
    // if (log_file) |f| {
    //     f.close();
    // }
    // log_file = null;
}

pub fn clientDisconnect(_: [][]const u8) !void {
    if (server) |s| {
        s.close();
    } else {
        std.log.err("Connection not established", .{});
    }
}

pub fn clientConnect(_: [][]const u8) !void {
    std.log.debug("Trying to connect to {s}", .{
        IP_address,
    });
    std.log.debug("Trying to connect to port {}", .{
        port,
    });
    server = try network.connectToHost(
        allocator,
        IP_address,
        port,
        .tcp,
    );
    if (server) |s| {
        std.log.info(
            "Connected to {}",
            .{try s.getRemoteEndPoint()},
        );
        std.log.info("Receiving line information...", .{});
        var buffer: [1024]u8 = undefined;
        _ = try s.receive(&buffer);
        std.log.debug("{s}", .{buffer});
        var tokenizer = std.mem.tokenizeSequence(
            u8,
            &buffer,
            ",",
        );
        const line_numbers = try std.fmt.parseInt(
            usize,
            tokenizer.next().?,
            0,
        );
        line_names = try allocator.alloc([]u8, line_numbers);
        var lines = try allocator.alloc(
            mcl.Config.Line,
            line_numbers,
        );
        defer allocator.free(lines);
        errdefer allocator.free(lines);
        for (0..line_numbers) |li| {
            if (tokenizer.next()) |token| {
                var line_description = std.mem.tokenizeSequence(
                    u8,
                    token,
                    ":",
                );
                const line_name =
                    line_description.next() orelse return error.LineNameNotReceived;
                line_names[li] = try allocator.alloc(u8, line_name.len);
                @memcpy(line_names[li], line_name);
                lines[li].axes = try std.fmt.parseInt(
                    mcl.Axis.Id.Line,
                    line_description.next() orelse return error.AxisNumberNotReceived,
                    0,
                );
                const range_len = try std.fmt.parseInt(
                    usize,
                    line_description.next() orelse return error.RangeNumberNotReceived,
                    0,
                );
                lines[li].ranges = try allocator.alloc(
                    mcl.Config.Line.Range,
                    range_len,
                );
                for (0..range_len) |ri| {
                    lines[li].ranges[ri].channel = std.meta.stringToEnum(
                        mcl.cc_link.Channel,
                        line_description.next() orelse return error.ChannelInfoNotReceived,
                    ) orelse return error.ChannelUnknown;
                    lines[li].ranges[ri].start = try std.fmt.parseInt(
                        mcl.cc_link.Id,
                        line_description.next() orelse return error.StartInfoDataNotReceived,
                        0,
                    );
                    lines[li].ranges[ri].end = try std.fmt.parseInt(
                        mcl.cc_link.Id,
                        line_description.next() orelse return error.EndInfoNotReceived,
                        0,
                    );
                }
                if (line_description.peek() != null) {
                    std.log.err(
                        "Remaining unexpected line description: {s}",
                        .{line_description.rest()},
                    );
                    return error.UnexpectedDataReceived;
                }
            }
        }
        try mcl.Config.validate(.{ .lines = lines });
        try mcl.init(allocator, .{ .lines = lines });
        line_speeds = try allocator.alloc(u5, line_numbers);
        line_accelerations = try allocator.alloc(u8, line_numbers);
        for (0..line_numbers) |i| {
            line_speeds[i] = 5;
            line_accelerations[i] = 78;
            std.log.debug(
                "line: {s}, #axis: {}, range info: {s}:{}:{}",
                .{
                    line_names[i],
                    lines[i].axes,
                    @tagName(lines[i].ranges[0].channel),
                    lines[i].ranges[0].start,
                    lines[i].ranges[0].end,
                },
            );
            defer allocator.free(lines[i].ranges);
        }
        std.log.info(
            "Received the line configuration for the following line:",
            .{},
        );
        const stdout = std.io.getStdOut().writer();
        for (line_names) |line_name| {
            try stdout.writeByte('\t');
            try stdout.writeAll(line_name);
            try stdout.writeByte('\n');
        }
        try autoInitializeCarrier(s);
    } else {
        std.log.err("Failed to connect to server", .{});
    }
}

fn autoInitializeCarrier(socket: network.Socket) !void {
    // A table indicating the start axis index of each line
    var total_axes: usize = 0;
    // Track the starting index of each line when the lines are cascaded
    var starting_axis_indices = try allocator.alloc(
        usize,
        mcl.lines.len,
    );
    for (mcl.lines, 0..) |line, idx| {
        starting_axis_indices[idx] = total_axes;
        total_axes += line.axes.len;
    }
    var hall_sensors: []bool = undefined;
    hall_sensors = try allocator.alloc(bool, total_axes * 2);
    // 1st: Map hall sensor status to `hall_sensors` variable
    hall_sensors = try mapHallSensors(
        hall_sensors,
        starting_axis_indices,
        socket,
    );
    // 2nd: iterate over `hall_sensors` to determine clusters
    // -> clusters: range of index (start and end)
    var enabled_sensor_count: usize = 0;
    var disabled_sensor_count: usize = 0;
    const SensorChain = enum { Enabled, Disabled };
    var chain: SensorChain = .Disabled;
    const Cluster = struct {
        start: usize,
        end: usize,
        direction: Direction,
        // the isolate algorithm requires which hall index is being used
        current_hall_index: usize,
        initialized_carriers: usize,
        carrier_ids: [1024]u10,
    };
    var clusters =
        try CircularBuffer(Cluster).initCapacity(allocator, 1024);
    var start_index: usize = 0; // starting axis when a cluster is detected
    var end_index: usize = 0;
    defer clusters.deinit();
    errdefer clusters.deinit();
    std.log.debug("{any}", .{hall_sensors});
    for (hall_sensors, 0..) |alarm_state, idx| {
        std.log.debug(
            "start_idx: {}, disabled: {}, enabled: {}, clusters: {}",
            .{
                start_index,
                disabled_sensor_count,
                enabled_sensor_count,
                clusters.items(),
            },
        );
        if (chain == .Disabled) {
            if (alarm_state == true) {
                chain = .Enabled;
                if (enabled_sensor_count != 0) {
                    enabled_sensor_count += disabled_sensor_count;
                }
                enabled_sensor_count += 1;
                // disabled to zero is required for looking the cluster ending
                disabled_sensor_count = 0;
            } else {
                disabled_sensor_count += 1;
                // when looking for the beginning of cluster
                if (disabled_sensor_count == 4 and enabled_sensor_count == 0) {
                    start_index += 1;
                    disabled_sensor_count -= 1;
                }
                // when looking for the ending of cluster
                if (enabled_sensor_count != 0 and disabled_sensor_count == 3) {
                    // check if the cluster is feasible for backward cluster
                    // backward is possible if three hall sensor is inactive
                    end_index = idx;
                    var backward_cluster = true;
                    std.log.debug("checking backward cluster...", .{});
                    for (start_index..start_index + 3) |i| {
                        std.log.debug("hall {}: {}", .{ i, hall_sensors[i] });
                        if (hall_sensors[i]) backward_cluster = false;
                    }
                    std.log.debug("backward: {}", .{backward_cluster});
                    var forward_cluster = true;
                    std.log.debug("checking forward cluster...", .{});
                    for (end_index - 2..end_index + 1) |i| {
                        std.log.debug("hall {}: {}", .{ i, hall_sensors[i] });
                        if (hall_sensors[i]) forward_cluster = false;
                    }
                    std.log.debug(
                        "backward: {}, forward: {}",
                        .{ backward_cluster, forward_cluster },
                    );
                    if (forward_cluster and backward_cluster and enabled_sensor_count <= 2) {
                        end_index = idx - 3;
                        std.log.debug(
                            "writing for multidirection cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .backward,
                            .current_hall_index = start_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                        start_index = end_index + 1;
                        disabled_sensor_count = 3;
                        enabled_sensor_count = 0;
                        end_index = 0;
                        continue;
                    } // When a cluster can isolate forward and backward
                    else if (forward_cluster and
                        backward_cluster and
                        enabled_sensor_count > 2)
                    {
                        std.log.debug(
                            "writing for multidirection cluster, start: {}, end: {}",
                            .{ start_index, end_index },
                        );
                        const mean_idx: f16 =
                            (@as(f16, @floatFromInt(end_index)) +
                                @as(f16, @floatFromInt(start_index))) / 2;
                        std.log.debug("mean_idx: {}", .{mean_idx});
                        if (@mod(mean_idx, 2) == 0) {
                            try clusters.writeItem(.{
                                .start = start_index,
                                .end = @intFromFloat(mean_idx),
                                .direction = .backward,
                                .current_hall_index = start_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                            try clusters.writeItem(.{
                                .start = @intFromFloat(mean_idx + 2),
                                .end = end_index,
                                .direction = .forward,
                                .current_hall_index = end_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                        } else {
                            try clusters.writeItem(.{
                                .start = start_index,
                                .end = @intFromFloat(mean_idx - 0.5),
                                .direction = .backward,
                                .current_hall_index = start_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                            try clusters.writeItem(.{
                                .start = @intFromFloat(mean_idx + 2),
                                .end = end_index,
                                .direction = .forward,
                                .current_hall_index = end_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                        }
                    } else if (forward_cluster and !backward_cluster) {
                        while (hall_sensors[start_index] == false) {
                            start_index += 1;
                        }
                        std.log.debug(
                            "writing for forward cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .forward,
                            .current_hall_index = end_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                    } else if (!forward_cluster and backward_cluster) {
                        while (hall_sensors[end_index] == false) {
                            end_index -= 1;
                        }
                        std.log.debug(
                            "writing for backward cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .backward,
                            .current_hall_index = start_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                    }
                    disabled_sensor_count = 0;
                    enabled_sensor_count = 0;
                    start_index = idx + 1;
                    end_index = 0;
                }
            }
            if (idx == hall_sensors.len - 1 and enabled_sensor_count != 0) {
                end_index = idx;
                std.log.debug(
                    "writing for the end of system cluster",
                    .{},
                );
                try clusters.writeItem(.{
                    .start = start_index,
                    .end = end_index,
                    .direction = .forward,
                    .current_hall_index = start_index,
                    .initialized_carriers = 0,
                    .carrier_ids = .{0} ** 1024,
                });
            }
        } else {
            if (alarm_state == false) {
                chain = .Disabled;
                disabled_sensor_count += 1;
            } else {
                enabled_sensor_count += 1;
                // when the final hall sensor is enabled, create a backward cluster
            }
            if (idx == hall_sensors.len - 1) {
                end_index = idx;
                std.log.debug(
                    "writing for the end of system cluster",
                    .{},
                );
                try clusters.writeItem(.{
                    .start = start_index,
                    .end = end_index,
                    .direction = .backward,
                    .current_hall_index = start_index,
                    .initialized_carriers = 0,
                    .carrier_ids = .{0} ** 1024,
                });
            }
        }
    }
    for (0..clusters.items()) |i| {
        const cluster = clusters.readItem().?;
        std.log.info(
            "cluster {}, start: {}, end: {}, direction: {}",
            .{ i + 1, cluster.start, cluster.end, cluster.direction },
        );
        try clusters.writeItem(cluster);
    }
    std.log.debug("\n\n", .{});
    // 3rd send command to the server based on the cluster
    var carrier_id: usize = 0;
    var initialized_carrier_id: usize = 0;
    while (clusters.readItem()) |cluster| {
        try command.checkCommandInterrupt();
        // if carrier detected in the current axis in interest, then move it
        // to the middle of axis. If there is any axis left in the cluster,
        // write to back to the clusters.
        const current_axis = cluster.current_hall_index / 2;
        var aux_axis: usize = undefined;
        if (cluster.direction == .backward and current_axis != 0) {
            aux_axis = current_axis - 1;
        } else if (cluster.direction == .forward and
            current_axis != total_axes - 1)
        {
            aux_axis = current_axis + 1;
        }
        std.log.debug(
            "cluster start: {}, cluster end: {}, current hall: {}",
            .{ cluster.start, cluster.end, cluster.current_hall_index },
        );
        std.log.debug(
            "initialized id: {}, current carrier id: {}",
            .{ initialized_carrier_id, carrier_id },
        );
        if (try checkCarrierExistence(current_axis, aux_axis, socket)) |carrier_info| {
            const detected_carrier_id = carrier_info.@"0";
            var is_carrier_member = false;
            for (cluster.carrier_ids) |id| {
                if (id == @as(u10, @truncate(detected_carrier_id))) {
                    is_carrier_member = true;
                    break;
                }
            }
            if (is_carrier_member == false) {
                try clusters.writeItem(cluster);
                continue;
            }
            if (detected_carrier_id > initialized_carrier_id) {
                initialized_carrier_id = detected_carrier_id;
            }
            const axis_idx = carrier_info.@"1";
            var line_idx: usize = undefined;
            for (starting_axis_indices, 0..) |starting_axis_index, idx| {
                if (axis_idx >= starting_axis_index) {
                    line_idx = idx;
                    break;
                }
            }
            std.log.debug(
                "cluster start: {}, cluster end: {}",
                .{ cluster.start, cluster.end },
            );
            const start_axis_idx = if (cluster.start % 2 == 0)
                cluster.start / 2
            else
                cluster.start / 2 + 1;
            const end_axis_idx = if (cluster.end % 2 == 0)
                cluster.end / 2 - 1
            else
                cluster.end / 2;
            const target_axis = if (cluster.direction == .backward)
                start_axis_idx
            else
                end_axis_idx;
            var param = std.mem.zeroes(mmc.ParamType(.set_command));
            param.command_code = .PositionMoveCarrierAxis;
            param.line_idx = @truncate(line_idx);
            param.axis_idx = @truncate(target_axis);
            param.carrier_id = @truncate(detected_carrier_id);
            param.speed = line_speeds[line_idx];
            param.acceleration = line_accelerations[line_idx];
            try sendMessage(
                .set_command,
                param,
                socket,
            );
            if ((cluster.current_hall_index < cluster.end - 1 and
                cluster.direction == .backward) or
                (cluster.current_hall_index > cluster.start + 1 and
                    cluster.direction == .forward))
            {
                try clusters.writeItem(.{
                    .current_hall_index = if (cluster.direction == .backward)
                        cluster.current_hall_index + 2
                    else
                        cluster.current_hall_index - 2,
                    .direction = cluster.direction,
                    .end = if (cluster.direction == .forward)
                        target_axis * 2 - 1
                    else
                        cluster.end,
                    .start = if (cluster.direction == .backward)
                        (target_axis + 1) * 2
                    else
                        cluster.start,
                    .carrier_ids = cluster.carrier_ids,
                    .initialized_carriers = cluster.initialized_carriers,
                });
            }
        } else if (initialized_carrier_id == carrier_id) {
            // Scan the hall sensor from the beginning of cluster (depending on
            // the direction).
            if (try assertNoProgressing(
                cluster.current_hall_index / 2,
                socket,
            ) == false) {
                try clusters.writeItem(cluster);
                std.log.debug("\n\n", .{});
                continue;
            }
            if (try checkHallStatus(
                cluster.current_hall_index,
                socket,
            ) == false) {
                try clusters.writeItem(.{
                    .current_hall_index = if (cluster.direction == .backward)
                        cluster.current_hall_index + 1
                    else
                        cluster.current_hall_index - 1,
                    .direction = cluster.direction,
                    .end = cluster.end,
                    .start = cluster.start,
                    .carrier_ids = cluster.carrier_ids,
                    .initialized_carriers = cluster.initialized_carriers,
                });
                std.log.debug("\n\n", .{});
                continue;
            }
            carrier_id += 1;
            const direction = cluster.direction;

            const axis_idx: usize = cluster.current_hall_index / 2;
            var link_axis: Direction = .no_direction;
            var line_idx: usize = undefined;

            if (cluster.current_hall_index % 2 == 1 and
                direction == .backward and
                cluster.end - cluster.current_hall_index > 0)
            {
                link_axis = .forward;
            } else if (cluster.current_hall_index % 2 == 0 and
                direction == .forward and
                cluster.current_hall_index - cluster.start > 0)
            {
                link_axis = .backward;
            }
            for (starting_axis_indices, 0..) |starting_axis_index, idx| {
                if (axis_idx >= starting_axis_index) {
                    line_idx = idx;
                    break;
                }
            }

            var param = std.mem.zeroes(mmc.ParamType(.set_command));
            param.command_code = if (direction == .forward)
                .IsolateForward
            else
                .IsolateBackward;
            param.line_idx = @truncate(line_idx);
            param.axis_idx = @truncate(axis_idx);
            param.carrier_id = @truncate(carrier_id);
            param.link_axis = link_axis;
            try sendMessage(
                .set_command,
                param,
                socket,
            );
            var new_cluster = cluster;
            new_cluster.initialized_carriers += 1;
            new_cluster.carrier_ids[new_cluster.initialized_carriers] =
                @truncate(carrier_id);
            try clusters.writeItem(new_cluster);
        } else {
            try clusters.writeItem(cluster);
        }
        std.log.debug("\n\n", .{});
    }
}

fn getFreeAxisIndex(
    start_hall_idx: usize,
    end_hall_idx: usize,
    direction: Direction,
    socket: network.Socket,
) !usize {
    const start_axis_idx = if (start_hall_idx % 2 == 0)
        start_hall_idx / 2
    else
        start_hall_idx / 2 + 1;
    const end_axis_idx = if (end_hall_idx % 2 == 0)
        end_hall_idx / 2 - 1
    else
        end_hall_idx / 2;
    var result = if (direction == .backward) start_axis_idx else end_axis_idx;
    std.log.debug(
        "result: {}, direction: {s}, start: {}, end: {}",
        .{ result, @tagName(direction), start_axis_idx, end_axis_idx },
    );
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        if (hall_sensor.axis_id - 1 == result) {
            if (direction == .forward and hall_sensor.hall_states.front) {
                std.log.debug(
                    "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
                    .{ direction == .forward, hall_sensor.hall_states.front },
                );
                result -= 1;
            } else if (direction == .backward and hall_sensor.hall_states.back) {
                std.log.debug(
                    "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
                    .{ direction == .forward, hall_sensor.hall_states.front },
                );
                result += 1;
            }
        }
        std.log.debug("result: {}", .{result});
    }
    return result;
}

fn checkHallStatus(hall_index: usize, socket: network.Socket) !bool {
    const hall_axis_id = hall_index / 2 + 1;
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        if (hall_axis_id == hall_sensor.axis_id) {
            if ((hall_index % 2 == 0 and hall_sensor.hall_states.back) or
                (hall_index % 2 != 0 and hall_sensor.hall_states.front))
            {
                return true;
            }
        }
    }
    return false;
}

/// check if there is a carrier at the specified axis
fn checkCarrierExistence(
    main_idx: usize,
    aux_idx: usize,
    socket: network.Socket,
) !?struct { usize, usize } {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_carriers = std.mem.readPackedInt(
        u10,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(u10);
    const IntType =
        @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
    var detected_carriers: usize = 0;
    while (detected_carriers < num_of_carriers) {
        try command.checkCommandInterrupt();
        const carrier_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_carriers += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const carrier: SystemState.Carrier = @bitCast(carrier_int);
        std.log.debug(
            "carrier_id: {}-first_axis: {}-second_axis: {}-location: {}",
            .{
                carrier.carrier_id,
                carrier.axis_ids.first,
                carrier.axis_ids.second,
                carrier.location,
            },
        );
        if ((carrier.axis_ids.first == main_idx + 1 or
            carrier.axis_ids.second == main_idx + 1) and
            (carrier.state == .BackwardIsolationCompleted or
                carrier.state == .ForwardIsolationCompleted))
        {
            return .{ carrier.carrier_id, main_idx };
        }
        if ((carrier.axis_ids.first == aux_idx + 1 or
            carrier.axis_ids.second == aux_idx + 1) and
            (carrier.state == .BackwardIsolationCompleted or
                carrier.state == .ForwardIsolationCompleted))
        {
            return .{ carrier.carrier_id, aux_idx };
        }
    }
    return null;
}

/// Map the hall sensor status from the server to `hall_sensors` variable
fn mapHallSensors(
    hall_sensors: []bool,
    starting_axis_indices: []usize,
    socket: network.Socket,
) ![]bool {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        const back_idx = starting_axis_indices[hall_sensor.line_id - 1] +
            (hall_sensor.axis_id - 1) * 2;
        const front_idx = starting_axis_indices[hall_sensor.line_id - 1] +
            (hall_sensor.axis_id - 1) * 2 + 1;
        hall_sensors[back_idx] = hall_sensor.hall_states.back;
        hall_sensors[front_idx] = hall_sensor.hall_states.front;
    }
    return hall_sensors;
}

/// assert that current axis does not have a moving carrier
fn assertNoProgressing(axis_idx: usize, socket: network.Socket) !bool {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_carriers = std.mem.readPackedInt(
        u10,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(u10);
    const IntType =
        @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
    var detected_carriers: usize = 0;
    while (detected_carriers < num_of_carriers) {
        try command.checkCommandInterrupt();
        const carrier_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_carriers += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const carrier: SystemState.Carrier = @bitCast(carrier_int);
        std.log.debug(
            "carrier_id: {}-first_axis: {}-second_axis: {}-location: {}",
            .{
                carrier.carrier_id,
                carrier.axis_ids.first,
                carrier.axis_ids.second,
                carrier.location,
            },
        );
        if ((carrier.axis_ids.first == axis_idx + 1 or
            carrier.axis_ids.second == axis_idx + 1) and
            (carrier.state == .ForwardIsolationProgressing or
                carrier.state == .BackwardIsolationProgressing))
        {
            return false;
        }
    }
    return true;
}

fn sendMessage(
    comptime kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.?,
    param: mmc.ParamType(kind),
    to_server: network.Socket,
) !void {
    const msg: mmc.Message(kind) =
        .{
            .kind = @intFromEnum(kind),
            ._unused_kind = 0,
            .param = param,
            ._rest_param = 0,
        };
    // std.log.debug("kind: {}", .{kind});
    // std.log.debug("param: {}", .{param});
    try to_server.writer().writeStruct(msg);
    // std.log.debug("message size: {}", .{@sizeOf(@TypeOf(msg))});
    // std.log.debug(
    //     "kind_size: {}, rest_kind: {}, param size: {}, rest: {}",
    //     .{
    //         @bitSizeOf(@TypeOf(msg.kind)),
    //         @bitSizeOf(@TypeOf(msg._unused_kind)),
    //         @bitSizeOf(@TypeOf(msg.param)),
    //         @bitSizeOf(@TypeOf(msg._rest_param)),
    //     },
    // );
    // try to_server.writer().writeAll(std.mem.asBytes(&msg));
    // std.log.debug("Wrote message {s}: {any}", .{
    //     @tagName(kind),
    //     std.mem.asBytes(&msg),
    // });
    if (kind == .set_command) {
        if (param.command_code == .IsolateForward) {
            std.log.info(
                "Sent command {s}\nline: {s}\naxis id: {}\ncarrier_id: {}\ndirection: {s}\nlink_axis: {s}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.axis_idx + 1,
                    param.carrier_id,
                    "forward",
                    @tagName(param.link_axis),
                },
            );
        } else if (param.command_code == .IsolateBackward) {
            std.log.info(
                "Sent command {s}\nline: {s}\naxis id: {}\ncarrier_id: {}\ndirection: {s}\nlink_axis: {s}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.axis_idx + 1,
                    param.carrier_id,
                    "backward",
                    @tagName(param.link_axis),
                },
            );
        } else if (param.command_code == .PositionMoveCarrierAxis) {
            std.log.info(
                "Sent command{s}\nline: {s}\ncarrier_id: {}\ndestination: {}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.carrier_id,
                    param.axis_idx + 1,
                },
            );
        }
    }
}
