const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const conn = mcl.connection;

var used_channels: [4]?conn.Channel = undefined;

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var config: Config = undefined;

const Direction = enum(u1) {
    backward = 0,
    forward = 1,
};

pub const Config = struct {
    connection: Connection = .@"CC-Link Ver.2",
    /// Minimum delay between polls through MELSEC, in us.
    min_poll_rate: u64 = std.time.us_per_ms * 5,
    lines: []Line,

    pub const Connection = enum(u8) {
        @"CC-Link Ver.2" = 0,
    };

    pub const Line = struct {
        name: []u8,
        channel: conn.Channel,
        start_station: u7,
        speed: u8 = 40,
        acceleration: u8 = 40,
        drivers: []Driver,
    };

    pub const Driver = struct {
        axes: [3]bool,
    };
};

pub fn init(c: Config) !void {
    if (c.lines.len == 0) {
        return error.NoLinesConfigureed;
    }
    for (c.lines) |line| {
        if (line.start_station < 1 or line.start_station > 64) {
            return error.InvalidLineStartStation;
        }
        if (line.drivers.len < 1 or line.drivers.len > 64) {
            return error.InvalidLineNumDrivers;
        }
        // Subtract 1 to account for included start station.
        var last_station: u7 = @intCast(line.drivers.len - 1);
        last_station += line.start_station;

        if (last_station > 64) {
            return error.InvalidLineDriversConfiguration;
        }
    }
    used_channels = .{ null, null, null, null };
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    config = .{
        .connection = c.connection,
        .min_poll_rate = c.min_poll_rate,
        .lines = try allocator.alloc(Config.Line, c.lines.len),
    };
    for (c.lines, 0..) |line, i| {
        for (&used_channels) |*_used_channel| {
            if (_used_channel.*) |used_channel| {
                if (used_channel == line.channel) break;
            } else {
                _used_channel.* = line.channel;
                break;
            }
        }
        config.lines[i] = .{
            .name = try allocator.alloc(u8, line.name.len),
            .channel = line.channel,
            .start_station = line.start_station,
            .speed = line.speed,
            .acceleration = line.acceleration,
            .drivers = try allocator.alloc(Config.Driver, line.drivers.len),
        };
        @memcpy(config.lines[i].name, line.name);
        @memcpy(config.lines[i].drivers, line.drivers);
    }

    try command.registry.put("MCL_VERSION", .{
        .name = "MCL_VERSION",
        .short_description = "Display the version of MCL.",
        .long_description =
        \\Print the currently linked version of the PMF Motion Control Library
        \\in Semantic Version format.
        ,
        .execute = &mclVersion,
    });
    errdefer _ = command.registry.orderedRemove("MCL_VERSION");
    try command.registry.put("CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect MCL with motion system.",
        .long_description =
        \\Initialize MCL's connection with the motion system. This command
        \\should be run before any other MCL command, and also after any power
        \\cycle of the motion system.
        ,
        .execute = &mclConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    try command.registry.put("DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End MCL's connection with the motion system. This command should be
        \\run after other MCL commands are completed.
        ,
        .execute = &mclDisconnect,
    });
    errdefer _ = command.registry.orderedRemove("DISCONNECT");
    try command.registry.put("SET_SPEED", .{
        .name = "SET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "speed percentage" },
        },
        .short_description = "Set the speed of slider movement for a line.",
        .long_description =
        \\Set the speed of slider movement for a line. The line is referenced
        \\by its name. The speed must be a whole integer number between 1 and
        \\100, inclusive.
        ,
        .execute = &mclSetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("SET_SPEED");
    try command.registry.put("SET_ACCELERATION", .{
        .name = "SET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "acceleration percentage" },
        },
        .short_description = "Set the acceleration of slider movement.",
        .long_description =
        \\Set the acceleration of slider movement for a line. The line is
        \\referenced by its name. The acceleration must be a whole integer
        \\number between 1 and 100, inclusive.
        ,
        .execute = &mclSetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("SET_ACCELERATION");
    try command.registry.put("AXIS_SLIDER", .{
        .name = "AXIS_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "result variable", .optional = true, .resolve = false },
        },
        .short_description = "Display slider on given axis, if exists.",
        .long_description =
        \\If a slider is recognized on the provided axis, print its slider ID.
        \\If a result variable name was provided, also store the slider ID in
        \\the variable.
        ,
        .execute = &mclAxisSlider,
    });
    errdefer _ = command.registry.orderedRemove("AXIS_SLIDER");
    try command.registry.put("RELEASE_AXIS_SERVO", .{
        .name = "RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Release the servo of a given axis.",
        .long_description =
        \\Release the servo of a given axis, allowing for free slider movement.
        \\This command should be run before sliders move within or exit from
        \\the system due to external influence.
        ,
        .execute = &mclAxisReleaseServo,
    });
    errdefer _ = command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put("WAIT_RELEASE_AXIS_SERVO", .{
        .name = "WAIT_RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Wait until a given axis has released its servo.",
        .long_description =
        \\Pause the execution of any further commands until the given axis has
        \\indicated that it has released its servo.
        ,
        .execute = &mclAxisWaitReleaseServo,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_RELEASE_AXIS_SERVO");
    try command.registry.put("HOME_SLIDER", .{
        .name = "HOME_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Home an unrecognized slider on the first axis.",
        .long_description =
        \\Home an unrecognized slider on the first axis. The unrecognized
        \\slider must be positioned in the correct homing position.
        ,
        .execute = &mclHomeSlider,
    });
    errdefer _ = command.registry.orderedRemove("HOME_SLIDER");
    try command.registry.put("WAIT_HOME_SLIDER", .{
        .name = "WAIT_HOME_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Wait until homing of slider is complete.",
        .long_description =
        \\Wait until homing is complete and a slider is recognized on the first
        \\axis. If an optional result variable name is provided, then store the
        \\recognized slider ID in the variable.
        ,
        .execute = &mclWaitHomeSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_HOME_SLIDER");
    try command.registry.put("RECOVER_SLIDER", .{
        .name = "RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "new slider ID" },
        },
        .short_description = "Recover an unrecognized slider on a given axis.",
        .long_description =
        \\Recover an unrecognized slider on a given axis. The provided slider
        \\ID must be a positive integer from 1 to 127 inclusive, and must be
        \\unique to other recognized slider IDs.
        ,
        .execute = &mclRecoverSlider,
    });
    errdefer _ = command.registry.orderedRemove("RECOVER_SLIDER");
    try command.registry.put("WAIT_RECOVER_SLIDER", .{
        .name = "WAIT_RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Wait until recovery of slider is complete.",
        .long_description =
        \\Wait until slider recovery is complete and a slider is recognized. 
        \\If an optional result variable name is provided, then store the
        \\recognized slider ID in the variable.
        ,
        .execute = &mclWaitRecoverSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_RECOVER_SLIDER");
    try command.registry.put("SLIDER_LOCATION", .{
        .name = "SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Display a slider's location.",
        .long_description =
        \\Print a given slider's location if it is currently recognized in the
        \\provided line. If a result variable name is provided, then store the
        \\slider's location in the variable.
        ,
        .execute = &mclSliderLocation,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_LOCATION");
    try command.registry.put("MOVE_SLIDER_AXIS", .{
        .name = "MOVE_SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move slider to target axis center.",
        .long_description =
        \\Move given slider to the center of target axis. The slider ID must be
        \\currently recognized within the motion system.
        ,
        .execute = &mclSliderPosMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_AXIS");
    try command.registry.put("MOVE_SLIDER_LOCATION", .{
        .name = "MOVE_SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination location" },
        },
        .short_description = "Move slider to target location.",
        .long_description =
        \\Move given slider to target location. The slider ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number.
        ,
        .execute = &mclSliderPosMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_LOCATION");
    try command.registry.put("MOVE_SLIDER_DISTANCE", .{
        .name = "MOVE_SLIDER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "distance" },
        },
        .short_description = "Move slider by a distance.",
        .long_description =
        \\Move given slider by a provided distance. The slider ID must be 
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement.
        ,
        .execute = &mclSliderPosMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_DISTANCE");
    try command.registry.put("WAIT_MOVE_SLIDER", .{
        .name = "WAIT_MOVE_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Wait for slider movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given slider is indicated as complete.
        ,
        .execute = &mclWaitMoveSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_MOVE_SLIDER");
}

pub fn deinit() void {
    arena.deinit();
    used_channels = .{ null, null, null, null };
}

fn mclVersion(_: [][]const u8) !void {
    std.log.info("MCL Version: {d}.{d}.{d}\n", .{
        mcl.version.major,
        mcl.version.minor,
        mcl.version.patch,
    });
}

fn mclConnect(_: [][]const u8) !void {
    for (used_channels) |_used_channel| {
        if (_used_channel) |used_channel| {
            try conn.openChannel(used_channel);
        }
    }

    for (config.lines) |line| {
        var station_index: u6 = @intCast(line.start_station - 1);
        for (line.drivers) |_| {
            const y: *conn.Station.Y = try conn.stationY(
                line.channel,
                station_index,
            );
            y.*.cc_link_enable = true;
            station_index += 1;
        }
        try conn.sendStationsY(line.channel, .{
            .start = @intCast(line.start_station - 1),
            .end = station_index - 1,
        });
    }
}

fn mclDisconnect(_: [][]const u8) !void {
    for (config.lines) |line| {
        var station_index: u6 = @intCast(line.start_station - 1);
        for (line.drivers) |_| {
            const y: *conn.Station.Y = try conn.stationY(
                line.channel,
                station_index,
            );
            y.*.cc_link_enable = false;
            station_index += 1;
        }
        try conn.sendStationsY(line.channel, .{
            .start = @intCast(line.start_station - 1),
            .end = station_index - 1,
        });
    }

    for (used_channels) |_used_channel| {
        if (_used_channel) |used_channel| {
            try conn.closeChannel(used_channel);
        }
    }
}

fn mclAxisSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);
    const result_var: []const u8 = params[2];
    var slider: ?i16 = null;

    const line: *const Config.Line = try matchLine(&config, line_name);

    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = start_station_index +
        @as(u6, @intCast(line.drivers.len - 1));

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var axis_counter: i16 = 0;
    var station_index: u6 = start_station_index;
    driver_loop: for (line.drivers) |driver| {
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i]) {
                axis_counter += 1;
                if (axis_counter == axis_id) {
                    const wr: *conn.Station.Wr = try conn.stationWr(
                        line.channel,
                        station_index,
                    );
                    const slider_number = wr.sliderNumber(i);
                    if (slider_number != 0) {
                        slider = slider_number;
                    }
                    break :driver_loop;
                }
            }
        }
        station_index += 1;
    }

    if (slider) |slider_id| {
        std.log.info("Slider {d} on axis {d}.\n", .{ slider_id, axis_id });
        if (result_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                result_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
            );
        }
    } else {
        std.log.info("No slider recognized on axis {d}.\n", .{axis_id});
    }
}

fn mclAxisReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);

    var axis_counter: i16 = 0;
    var station_index: u6 = start_station_index;
    driver_loop: for (line.drivers) |driver| {
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i]) {
                axis_counter += 1;
                if (axis_counter == axis_id) {
                    axis_counter = i;
                    break :driver_loop;
                }
            }
        }
        station_index += 1;
    } else {
        return error.TargetAxisNotFound;
    }

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    const x: *conn.Station.X = try conn.stationX(line.channel, station_index);
    ww.*.target_axis_number = axis_id;
    try conn.sendStationWw(line.channel, station_index);
    try conn.setStationY(
        line.channel,
        station_index,
        0x5,
    );
    // Reset on error as well as on success.
    defer conn.resetStationY(line.channel, station_index, 0x5) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStation(line.channel, station_index);
        if (!x.servoActive(@intCast(axis_counter))) break;
    }
}

fn mclAxisWaitReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);

    var axis_counter: i16 = 0;
    var station_index: u6 = start_station_index;
    driver_loop: for (line.drivers) |driver| {
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i]) {
                axis_counter += 1;
                if (axis_counter == axis_id) {
                    axis_counter = i;
                    break :driver_loop;
                }
            }
        }
        station_index += 1;
    } else {
        return error.TargetAxisNotFound;
    }

    const x: *conn.Station.X = try conn.stationX(line.channel, station_index);
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStation(line.channel, station_index);
        if (x.servoActive(@intCast(axis_counter))) return;
    }
}

fn mclHomeSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line: *const Config.Line = try matchLine(&config, line_name);
    try waitCommandReady(line.channel, 0);
    const ww: *conn.Station.Ww = try conn.stationWw(line.channel, 0);
    ww.*.command_code = .Home;
    try sendCommand(line.channel, 0);
}

fn mclWaitHomeSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const result_var: []const u8 = params[1];

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);

    var slider: ?i16 = null;
    const wr: *conn.Station.Wr = try conn.stationWr(
        line.channel,
        start_station_index,
    );
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStation(line.channel, 0);

        if (wr.slider_number.axis1 != 0) {
            slider = wr.slider_number.axis1;
            break;
        }
    }

    std.log.info("Slider {d} homed.\n", .{slider.?});
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{slider.?}),
        );
    }
}

fn mclSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_speed = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_speed < 1 or slider_speed > 100) return error.InvalidSpeed;

    const line: *Config.Line = try matchLine(&config, line_name);
    line.*.speed = slider_speed;
}

fn mclSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_acceleration = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_acceleration < 1 or slider_acceleration > 100)
        return error.InvalidAcceleration;

    const line: *Config.Line = try matchLine(&config, line_name);
    line.*.acceleration = slider_acceleration;
}

fn mclSliderLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(i16, params[1], 0);
    if (slider_id == 0) return error.InvalidSliderId;
    const result_var: []const u8 = params[2];

    const line: *const Config.Line = try matchLine(&config, line_name);

    const start_index_station: u6 = @intCast(line.start_station - 1);
    const end_index_station: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_index_station;
    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_index_station, .end = end_index_station },
    );

    var station_index: u6 = start_index_station;
    var location: conn.Station.Distance = undefined;
    driver_loop: for (line.drivers) |driver| {
        const wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            station_index,
        );
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i] and wr.sliderNumber(i) == slider_id) {
                location = wr.sliderLocation(i);
                break :driver_loop;
            }
        }
        station_index += 1;
    } else {
        return error.SliderIdNotFound;
    }

    std.log.info(
        "Slider {d} location: {d}.{d}mm",
        .{ slider_id, location.mm, location.um },
    );
    if (result_var.len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(result_var, try std.fmt.bufPrint(
            &float_buf,
            "{d}.{d}",
            .{ location.mm, location.um },
        ));
    }
}

fn mclSliderPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: i16 = try std.fmt.parseInt(i16, params[1], 0);
    const axis_id: i16 = try std.fmt.parseInt(i16, params[2], 0);
    if (slider_id == 0) return error.InvalidSliderId;

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;

    std.log.debug("Polling CC-Link...", .{});
    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = start_station_index;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;
    // Find station and axis of slider.
    std.log.debug("Parsing drivers...", .{});
    driver_loop: for (line.drivers) |driver| {
        const wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            station_index,
        );
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i] and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axes[j]) {
                        break;
                    }
                } else {
                    last_axis = true;
                }
                break :driver_loop;
            }
            axis_index += 1;
        }
        station_index += 1;
    } else {
        return error.SliderIdNotFound;
    }

    // If slider is between two drivers, stop traffic transmission.
    var stopped_transmission: ?Direction = null;
    if (last_axis and station_index < end_station_index) {
        std.log.debug("Checking transmission stop conditions...", .{});
        const next_station_index: u6 = station_index + 1;
        const next_station_slice_index: usize =
            station_index - start_station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (line.drivers[next_station_slice_index].axes[i]) {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Destination axis is at or beyond next driver.
                    // Forward movement.
                    if (axis_id > axis_index + 1) {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Destination is at or before current driver.
                    // Backward movement.
                    else {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .backward,
                        );
                        stopped_transmission = .backward;
                    }
                }
                break;
            }
        }
    }

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    std.log.debug("Waiting for command ready state...", .{});
    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .MoveSliderToAxisByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.target_axis_number = axis_id;
    ww.*.speed_percentage = line.speed;
    ww.*.acceleration_percentage = line.acceleration;
    std.log.debug("Sending command...", .{});
    try sendCommand(line.channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: i16 = try std.fmt.parseInt(i16, params[1], 0);
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0) return error.InvalidSliderId;

    const location: conn.Station.Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = start_station_index;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;

    var wr: *conn.Station.Wr = undefined;
    // Find station and axis of slider.
    driver_loop: for (line.drivers) |driver| {
        wr = try conn.stationWr(line.channel, station_index);
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i] and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axes[j]) {
                        break;
                    }
                } else {
                    last_axis = true;
                }
                break :driver_loop;
            }
            axis_index += 1;
        }
        station_index += 1;
    } else {
        return error.SliderIdNotFound;
    }

    var stopped_transmission: ?Direction = null;
    if (last_axis and station_index < end_station_index) {
        const next_station_index: u6 = station_index + 1;
        const next_station_slice_index: usize =
            station_index - start_station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (line.drivers[next_station_slice_index].axes[i]) {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Destination location is in front of current location.
                    // Forward movement.
                    if (location.mm > wr.sliderLocation(i).mm or
                        (location.mm == wr.sliderLocation(i).mm and
                        location.um > wr.sliderLocation(i).um))
                    {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Destination location is behind current location.
                    // Backward movement.
                    else {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .backward,
                        );
                        stopped_transmission = .backward;
                    }
                }
                break;
            }
        }
    }

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .MoveSliderToLocationByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.location_distance = location;
    ww.*.speed_percentage = line.speed;
    ww.*.acceleration_percentage = line.acceleration;
    try sendCommand(line.channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(i16, params[1], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0) return error.InvalidSliderId;

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;

    const distance: conn.Station.Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = start_station_index;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;

    var wr: *conn.Station.Wr = undefined;
    // Find station and axis of slider.
    driver_loop: for (line.drivers) |driver| {
        wr = try conn.stationWr(line.channel, station_index);
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i] and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axes[j]) {
                        break;
                    }
                } else {
                    last_axis = true;
                }
                break :driver_loop;
            }
            axis_index += 1;
        }
        station_index += 1;
    } else {
        return error.SliderIdNotFound;
    }

    var stopped_transmission: ?Direction = null;
    if (last_axis and station_index < end_station_index) {
        const next_station_index: u6 = station_index + 1;
        const next_station_slice_index: usize =
            station_index - start_station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );

        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (line.drivers[next_station_slice_index].axes[i]) {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Distance is positive. Forward movement.
                    if (distance.mm > 0 or
                        (distance.mm == 0 and distance.um > 0))
                    {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Distance is negative or 0. Backward movement.
                    else {
                        try stopTrafficTransmission(
                            line.*,
                            station_index,
                            .backward,
                        );
                        stopped_transmission = .backward;
                    }
                }
            }
        }
    }

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .MoveSliderDistanceByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.location_distance = distance;
    ww.*.speed_percentage = line.speed;
    ww.*.acceleration_percentage = line.acceleration;
    try sendCommand(line.channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclWaitMoveSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(i16, params[1], 0);
    if (slider_id == 0) return error.InvalidSliderId;

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;

    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStations(
            line.channel,
            .{ .start = start_station_index, .end = end_station_index },
        );

        var station_index: u6 = start_station_index;
        var slider_id_found: bool = false;
        for (line.drivers) |driver| {
            try command.checkCommandInterrupt();
            const wr: *conn.Station.Wr = try conn.stationWr(
                line.channel,
                station_index,
            );
            for (0..3) |_i| {
                const i: u2 = @intCast(_i);
                if (driver.axes[i] and wr.sliderNumber(i) == slider_id) {
                    slider_id_found = true;
                    if (wr.sliderState(i) == .PosMoveCompleted) {
                        return;
                    }
                }
            }
            station_index += 1;
        }

        if (!slider_id_found) {
            return error.SliderIdNotFound;
        }
    }
}

fn mclRecoverSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: i16 = try std.fmt.parseUnsigned(i16, params[1], 0);
    const new_slider_id: i16 = try std.fmt.parseUnsigned(i16, params[2], 0);
    if (new_slider_id < 1 or new_slider_id > 127) return error.InvalidSliderID;

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var axis_counter: i16 = 0;
    var station_index: u6 = start_station_index;
    driver_loop: for (line.drivers) |driver| {
        try command.checkCommandInterrupt();
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i]) {
                axis_counter += 1;
                if (axis_counter == axis) {
                    // Slider recovery uses driver local axis ID (1-3).
                    axis_counter = i + 1;
                    break :driver_loop;
                }
            }
        }
        station_index += 1;
    } else {
        return error.TargetAxisNotFound;
    }

    const ww: *conn.Station.Ww = try conn.stationWw(
        line.channel,
        station_index,
    );

    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .RecoverSliderAtAxis;
    ww.*.target_axis_number = axis_counter;
    ww.*.command_slider_number = new_slider_id;
    try sendCommand(line.channel, station_index);
}

fn mclWaitRecoverSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: i16 = try std.fmt.parseUnsigned(i16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);

    var slider_id: i16 = undefined;
    var axis_counter: i16 = 0;
    var station_index: u6 = start_station_index;
    driver_search: for (line.drivers) |driver| {
        try command.checkCommandInterrupt();
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axes[i]) {
                axis_counter += 1;
                if (axis_counter == axis) {
                    const wr: *conn.Station.Wr = try conn.stationWr(
                        line.channel,
                        station_index,
                    );
                    while (true) {
                        try command.checkCommandInterrupt();
                        std.time.sleep(
                            std.time.ns_per_us * config.min_poll_rate,
                        );
                        try conn.pollStation(line.channel, station_index);

                        const slider_number = wr.sliderNumber(i);
                        if (slider_number != 0 and
                            wr.sliderState(i) == .PosMoveCompleted)
                        {
                            slider_id = slider_number;
                            break :driver_search;
                        }
                    }
                }
            }
        }
        station_index += 1;
    } else {
        return error.TargetAxisNotFound;
    }

    std.log.info("Slider {d} recovered.\n", .{slider_id});
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
        );
    }
}

fn matchLine(c: *Config, name: []const u8) !*Config.Line {
    for (c.lines) |*line| {
        if (std.mem.eql(u8, line.name, name)) return line;
    } else {
        return error.LineNameNotFound;
    }
}

fn waitCommandReady(c: conn.Channel, station_index: u6) !void {
    const x: *conn.Station.X = try conn.stationX(c, station_index);
    std.log.debug("Waiting for command ready state...", .{});
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStation(c, station_index);
        if (x.ready_for_command) break;
    }
}

fn sendCommand(c: conn.Channel, station_index: u6) !void {
    const x: *conn.Station.X = try conn.stationX(c, station_index);

    std.log.debug("Sending command...", .{});
    try conn.sendStationWw(c, station_index);
    try conn.setStationY(c, station_index, 0x2);
    send_command: while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try conn.pollStation(c, station_index);
        if (x.command_received) {
            std.log.debug("Resetting command received flag...", .{});
            try conn.resetStationY(c, station_index, 0x2);
            try conn.setStationY(c, station_index, 0x3);
            reset_received: while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(c, station_index);
                if (!x.command_received) {
                    try conn.resetStationY(c, station_index, 0x3);
                    break :reset_received;
                }
            }
            break :send_command;
        }
    }
}

/// Handle traffic transmission stop when a slider positioned between current
/// and next station begins movement.
fn stopTrafficTransmission(
    line: Config.Line,
    station_index: u6,
    direction: Direction,
) !void {
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;
    if (station_index < start_station_index or
        station_index >= end_station_index) return;
    std.log.debug("Stopping traffic transmission...", .{});

    const station: conn.Station.Reference =
        try conn.station(line.channel, station_index);
    const next_station: conn.Station.Reference = try conn.station(
        line.channel,
        station_index + 1,
    );

    var state: conn.Station.Wr.SliderStateCode = undefined;
    var next_state: conn.Station.Wr.SliderStateCode = undefined;

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (line.drivers[station_index - start_station_index].axes[2 - i]) {
            state = station.wr.sliderState(2 - i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (line.drivers[station_index - start_station_index + 1].axes[i]) {
            next_state = next_station.wr.sliderState(i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    if (direction == .forward) {
        if ((next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted) and station_index > 0)
        {
            // Stop traffic transmission from current station to previous
            // station.
            try conn.setStationY(line.channel, station_index - 1, 0xA);
            const prev_x: *conn.Station.X = try conn.stationX(
                line.channel,
                station_index - 1,
            );
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index - 1);
                if (prev_x.transmission_stopped.from_next) {
                    break;
                }
            }
        } else if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted)
        {
            // Stop traffic transmission from previous station to current
            // station.
            try conn.setStationY(line.channel, station_index, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index);
                if (station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        }
    } else {
        if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted or
            state == .None)
        {
            // Stop traffic transmission from current station to next station.
            try conn.setStationY(line.channel, station_index + 1, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index + 1);
                if (next_station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        } else if (next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted or
            next_state == .None)
        {
            // Stop traffic transmission from next station to current station.
            try conn.setStationY(line.channel, station_index, 0xA);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index);
                if (station.x.transmission_stopped.from_next) {
                    break;
                }
            }
        }
    }
}

/// Handle traffic transmission start after slider movement command.
fn restartTrafficTransmission(
    line: Config.Line,
    station_index: u6,
    direction: Direction,
) !void {
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 =
        @as(u6, @intCast(line.drivers.len - 1)) + start_station_index;
    if (station_index < start_station_index or
        station_index >= end_station_index) return;
    std.log.debug("Restarting traffic transmission...", .{});

    const station: conn.Station.Reference =
        try conn.station(line.channel, station_index);
    const next_station: conn.Station.Reference = try conn.station(
        line.channel,
        station_index + 1,
    );

    var state: conn.Station.Wr.SliderStateCode = undefined;
    var next_state: conn.Station.Wr.SliderStateCode = undefined;

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (line.drivers[station_index - start_station_index].axes[2 - i]) {
            state = station.wr.sliderState(2 - i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (line.drivers[station_index - start_station_index + 1].axes[i]) {
            next_state = next_station.wr.sliderState(i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    if (direction == .forward) {
        if ((next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted) and station_index > 0)
        {
            // Start traffic transmission from current station to previous
            // station.
            try conn.resetStationY(line.channel, station_index - 1, 0xA);
            const prev_x: *conn.Station.X = try conn.stationX(
                line.channel,
                station_index - 1,
            );
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index - 1);
                if (!prev_x.transmission_stopped.from_next) {
                    break;
                }
            }
        } else if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted)
        {
            // Start traffic transmission from previous station to current
            // station.
            try conn.resetStationY(line.channel, station_index, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index);
                if (!station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        }
    } else {
        if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted or
            state == .None)
        {
            // Start traffic transmission from current station to next station.
            try conn.resetStationY(line.channel, station_index + 1, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index + 1);
                if (!next_station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        } else if (next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted or
            next_state == .None)
        {
            // Start traffic transmission from next station to current station.
            try conn.resetStationY(line.channel, station_index, 0xA);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try conn.pollStation(line.channel, station_index);
                if (!station.x.transmission_stopped.from_next) {
                    break;
                }
            }
        }
    }
}
