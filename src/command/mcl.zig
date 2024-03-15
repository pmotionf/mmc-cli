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
    lines: []Line,

    pub const Line = struct {
        name: []u8,
        channel: conn.Channel,
        start_station: u7,
        end_station: u7,
        total_axes: u15,
        speed: u8 = 40,
        acceleration: u8 = 40,
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
        if (line.end_station < line.start_station or line.end_station > 64) {
            return error.InvalidLineEndStation;
        }
        const num_stations: usize = line.end_station - line.start_station + 1;
        if (line.total_axes < num_stations or
            line.total_axes > num_stations * 3)
        {
            return error.InvalidNumberOfAxes;
        }
    }
    used_channels = .{ null, null, null, null };
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    config = .{
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
            .end_station = line.end_station,
            .total_axes = line.total_axes,
            .speed = line.speed,
            .acceleration = line.acceleration,
        };
        @memcpy(config.lines[i].name, line.name);
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
    try command.registry.put("CALIBRATE", .{
        .name = "CALIBRATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Calibrate a system line.",
        .long_description =
        \\Calibrate a system line. An uninitialized slider must be positioned
        \\at the start of the line such that the first axis has both hall
        \\alarms active.
        ,
        .execute = &mclCalibrate,
    });
    errdefer _ = command.registry.orderedRemove("CALIBRATE");
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
        for (line.start_station - 1..line.end_station) |i| {
            const station_index: u6 = @intCast(i);
            const y: *conn.Station.Y = try conn.stationY(
                line.channel,
                station_index,
            );
            y.*.cc_link_enable = true;
        }
        try conn.sendStationsY(line.channel, .{
            .start = @intCast(line.start_station - 1),
            .end = @intCast(line.end_station - 1),
        });
    }
}

fn mclDisconnect(_: [][]const u8) !void {
    for (config.lines) |line| {
        for (line.start_station - 1..line.end_station) |i| {
            const station_index: u6 = @intCast(i);
            const y: *conn.Station.Y = try conn.stationY(
                line.channel,
                station_index,
            );
            y.*.cc_link_enable = false;
        }
        try conn.sendStationsY(line.channel, .{
            .start = @intCast(line.start_station - 1),
            .end = @intCast(line.end_station - 1),
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

    const line: *const Config.Line = try matchLine(&config, line_name);

    if (axis_id < 1 or axis_id > line.total_axes) {
        return error.InvalidAxis;
    }

    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);

    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    const axis_index: i16 = axis_id - 1;
    const station_index: u6 = @intCast(@divTrunc(axis_index, 3));
    const local_axis_index: u2 = @intCast(@rem(axis_index, 3));

    const wr: *conn.Station.Wr = try conn.stationWr(
        line.channel,
        station_index,
    );
    const slider_id = wr.sliderNumber(local_axis_index);

    if (slider_id != 0) {
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
    if (axis_id < 1 or axis_id > line.total_axes) {
        return error.InvalidAxis;
    }

    const axis_index: i16 = axis_id - 1;
    const station_index: u6 = @intCast(@divTrunc(axis_index, 3));
    const local_axis_index: u2 = @intCast(@rem(axis_index, 3));

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    const x: *conn.Station.X = try conn.stationX(line.channel, station_index);
    ww.*.target_axis_number = local_axis_index;
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
        try conn.pollStation(line.channel, station_index);
        if (!x.servoActive(local_axis_index)) break;
    }
}

fn mclAxisWaitReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line: *const Config.Line = try matchLine(&config, line_name);
    if (axis_id < 1 or axis_id > line.total_axes) {
        return error.InvalidAxis;
    }

    const axis_index: i16 = axis_id - 1;
    const station_index: u6 = @intCast(@divTrunc(axis_index, 3));
    const local_axis_index: u2 = @intCast(@rem(axis_index, 3));

    const x: *conn.Station.X = try conn.stationX(line.channel, station_index);
    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStation(line.channel, station_index);
        if (x.servoActive(local_axis_index)) return;
    }
}

fn mclCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line: *const Config.Line = try matchLine(&config, line_name);

    const station_index: u6 = @intCast(line.start_station - 1);

    try waitCommandReady(line.channel, station_index);
    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    ww.*.command_code = .Calibration;
    try sendCommand(line.channel, station_index);
}

fn mclHomeSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line: *const Config.Line = try matchLine(&config, line_name);
    const station_index: u6 = @intCast(line.start_station - 1);
    try waitCommandReady(line.channel, station_index);
    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    ww.*.command_code = .Home;
    try sendCommand(line.channel, station_index);
}

fn mclWaitHomeSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const result_var: []const u8 = params[1];

    const line: *const Config.Line = try matchLine(&config, line_name);
    const station_index: u6 = @intCast(line.start_station - 1);

    var slider: ?i16 = null;
    const wr: *conn.Station.Wr =
        try conn.stationWr(line.channel, station_index);
    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStation(line.channel, station_index);

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
    if (slider_id < 1 or slider_id > 127) return error.InvalidSliderId;
    const result_var: []const u8 = params[2];

    const line: *const Config.Line = try matchLine(&config, line_name);

    const start_index_station: u6 = @intCast(line.start_station - 1);
    const end_index_station: u6 = @intCast(line.end_station - 1);
    try conn.pollStations(
        line.channel,
        .{ .start = start_index_station, .end = end_index_station },
    );

    var location: conn.Station.Distance = undefined;
    driver_loop: for (start_index_station..line.end_station) |i| {
        const station_index: u6 = @intCast(i);
        const wr: *conn.Station.Wr =
            try conn.stationWr(line.channel, station_index);
        for (0..3) |j| {
            const local_axis_index: u2 = @intCast(j);
            if (wr.sliderNumber(local_axis_index) == slider_id) {
                location = wr.sliderLocation(local_axis_index);
                break :driver_loop;
            }
        }
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
    if (slider_id < 1 or slider_id > 127) return error.InvalidSliderId;

    const line: *const Config.Line = try matchLine(&config, line_name);
    if (axis_id < 1 or axis_id > line.total_axes) {
        return error.InvalidAxis;
    }

    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = undefined;
    var local_axis_index: u2 = undefined;
    driver_loop: for (start_station_index..line.end_station) |i| {
        station_index = @intCast(i);
        const wr: *conn.Station.Wr =
            try conn.stationWr(line.channel, station_index);
        for (0..3) |j| {
            local_axis_index = @intCast(j);
            if (wr.sliderNumber(local_axis_index) == slider_id) {
                break :driver_loop;
            }
        }
    } else {
        return error.SliderIdNotFound;
    }

    const axis_index: u15 = station_index * 3 + local_axis_index;

    // If slider is between two drivers, stop traffic transmission.
    var stopped_transmission: ?Direction = null;
    if (local_axis_index == 2 and station_index < end_station_index) {
        std.log.debug("Checking transmission stop conditions...", .{});
        const next_station_index: u6 = station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        if (next_wr.sliderNumber(0) == slider_id) {
            // Destination axis is at or beyond next driver.
            // Forward movement.
            if (axis_id > axis_index + 1) {
                try stopTrafficTransmission(line.*, station_index, .forward);
                stopped_transmission = .forward;
            }
            // Destination is at or before current driver.
            // Backward movement.
            else {
                try stopTrafficTransmission(line.*, station_index, .backward);
                stopped_transmission = .backward;
            }
        }
    }

    const ww: *conn.Station.Ww =
        try conn.stationWw(line.channel, station_index);
    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .MoveSliderToAxisByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.target_axis_number = axis_id;
    ww.*.speed_percentage = line.speed;
    ww.*.acceleration_percentage = line.acceleration;
    try sendCommand(line.channel, station_index);

    if (stopped_transmission) |dir| {
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: i16 = try std.fmt.parseInt(i16, params[1], 0);
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id < 1 or slider_id > 127) return error.InvalidSliderId;

    const location: conn.Station.Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = undefined;
    var local_axis_index: u2 = undefined;
    var wr: *conn.Station.Wr = undefined;
    driver_loop: for (start_station_index..line.end_station) |i| {
        station_index = @intCast(i);
        wr = try conn.stationWr(line.channel, station_index);
        for (0..3) |j| {
            local_axis_index = @intCast(j);
            if (wr.sliderNumber(local_axis_index) == slider_id) {
                break :driver_loop;
            }
        }
    } else {
        return error.SliderIdNotFound;
    }

    var stopped_transmission: ?Direction = null;
    if (local_axis_index == 2 and station_index < end_station_index) {
        const next_station_index: u6 = station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        if (next_wr.sliderNumber(0) == slider_id) {
            // Destination location is in front of current location.
            // Forward movement.
            if (location.mm > wr.slider_location.axis1.mm or
                (location.mm == wr.slider_location.axis1.mm and
                location.um > wr.slider_location.axis1.um))
            {
                try stopTrafficTransmission(line.*, station_index, .forward);
                stopped_transmission = .forward;
            }
            // Destination location is behind current location.
            // Backward movement.
            else {
                try stopTrafficTransmission(line.*, station_index, .backward);
                stopped_transmission = .backward;
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
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(i16, params[1], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id < 1 or slider_id > 127) return error.InvalidSliderId;

    const distance: conn.Station.Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    var station_index: u6 = undefined;
    var local_axis_index: u2 = undefined;
    var wr: *conn.Station.Wr = undefined;
    driver_loop: for (start_station_index..line.end_station) |i| {
        station_index = @intCast(i);
        wr = try conn.stationWr(line.channel, station_index);
        for (0..3) |j| {
            local_axis_index = @intCast(j);
            if (wr.sliderNumber(local_axis_index) == slider_id) {
                break :driver_loop;
            }
        }
    } else {
        return error.SliderIdNotFound;
    }

    var stopped_transmission: ?Direction = null;
    if (local_axis_index == 2 and station_index < end_station_index) {
        const next_station_index: u6 = station_index + 1;
        const next_wr: *conn.Station.Wr = try conn.stationWr(
            line.channel,
            next_station_index,
        );

        // Check first axis of next driver to see if slider is between drivers.
        if (next_wr.sliderNumber(0) == slider_id) {
            // Distance is positive. Forward movement.
            if (distance.mm > 0 or (distance.mm == 0 and distance.um > 0)) {
                try stopTrafficTransmission(line.*, station_index, .forward);
                stopped_transmission = .forward;
            }
            // Distance is negative or 0. Backward movement.
            else {
                try stopTrafficTransmission(line.*, station_index, .backward);
                stopped_transmission = .backward;
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
        try restartTrafficTransmission(line.*, station_index, dir);
    }
}

fn mclWaitMoveSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(i16, params[1], 0);
    if (slider_id < 1 or slider_id > 127) return error.InvalidSliderId;

    const line: *const Config.Line = try matchLine(&config, line_name);
    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);

    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStations(
            line.channel,
            .{ .start = start_station_index, .end = end_station_index },
        );

        var slider_id_found: bool = false;
        for (start_station_index..line.end_station) |i| {
            const station_index: u6 = @intCast(i);
            const wr: *conn.Station.Wr = try conn.stationWr(
                line.channel,
                station_index,
            );
            for (0..3) |j| {
                const local_axis_index: u2 = @intCast(j);
                if (wr.sliderNumber(local_axis_index) == slider_id) {
                    slider_id_found = true;
                    if (wr.sliderState(
                        local_axis_index,
                    ) == .PosMoveCompleted) {
                        return;
                    }
                }
            }
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
    if (axis < 1 or axis > line.total_axes) {
        return error.InvalidAxis;
    }

    const start_station_index: u6 = @intCast(line.start_station - 1);
    const end_station_index: u6 = @intCast(line.end_station - 1);
    try conn.pollStations(
        line.channel,
        .{ .start = start_station_index, .end = end_station_index },
    );

    const axis_index: u15 = @intCast(axis - 1);
    const station_index: u6 = @intCast(axis_index / 3);
    const local_axis_index: u2 = @intCast(axis_index % 3);

    const ww: *conn.Station.Ww = try conn.stationWw(
        line.channel,
        station_index,
    );
    try waitCommandReady(line.channel, station_index);
    ww.*.command_code = .RecoverSliderAtAxis;
    ww.*.target_axis_number = local_axis_index;
    ww.*.command_slider_number = new_slider_id;
    try sendCommand(line.channel, station_index);
}

fn mclWaitRecoverSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: i16 = try std.fmt.parseUnsigned(i16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line: *const Config.Line = try matchLine(&config, line_name);
    if (axis < 1 or axis > line.total_axes) {
        return error.InvalidAxis;
    }

    const axis_index: u15 = @intCast(axis - 1);
    const station_index: u6 = @intCast(axis_index / 3);
    const local_axis_index: u2 = @intCast(axis_index % 3);

    var slider_id: i16 = undefined;
    const wr: *conn.Station.Wr = try conn.stationWr(
        line.channel,
        station_index,
    );
    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStation(line.channel, station_index);

        const slider_number = wr.sliderNumber(local_axis_index);
        if (slider_number != 0 and
            wr.sliderState(local_axis_index) == .PosMoveCompleted)
        {
            slider_id = slider_number;
            break;
        }
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
        try conn.pollStation(c, station_index);
        if (x.ready_for_command) break;
    }
}

fn sendCommand(c: conn.Channel, station_index: u6) !void {
    const x: *conn.Station.X = try conn.stationX(c, station_index);

    std.log.debug("Sending command...", .{});
    try conn.sendStationWw(c, station_index);
    try conn.setStationY(c, station_index, 0x2);
    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStation(c, station_index);
        if (x.command_received) {
            break;
        }
    }

    std.log.debug("Resetting command received flag...", .{});
    try conn.resetStationY(c, station_index, 0x2);
    try conn.setStationY(c, station_index, 0x3);
    while (true) {
        try command.checkCommandInterrupt();
        try conn.pollStation(c, station_index);
        if (!x.command_received) {
            try conn.resetStationY(c, station_index, 0x3);
            break;
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
    const end_station_index: u6 = @intCast(line.end_station - 1);
    if (station_index < start_station_index or
        station_index >= end_station_index) return;
    std.log.debug("Stopping traffic transmission...", .{});

    const station: conn.Station.Reference =
        try conn.station(line.channel, station_index);
    const next_station: conn.Station.Reference = try conn.station(
        line.channel,
        station_index + 1,
    );

    const state = station.wr.slider_state.axis3;
    const next_state = next_station.wr.slider_state.axis1;

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
    const end_station_index: u6 = @intCast(line.end_station - 1);
    if (station_index < start_station_index or
        station_index >= end_station_index) return;
    std.log.debug("Restarting traffic transmission...", .{});

    const station: conn.Station.Reference =
        try conn.station(line.channel, station_index);
    const next_station: conn.Station.Reference = try conn.station(
        line.channel,
        station_index + 1,
    );

    const state = station.wr.slider_state.axis3;
    const next_state = next_station.wr.slider_state.axis1;

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
                try conn.pollStation(line.channel, station_index);
                if (!station.x.transmission_stopped.from_next) {
                    break;
                }
            }
        }
    }
}
