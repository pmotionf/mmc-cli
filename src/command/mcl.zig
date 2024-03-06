const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");

var slider_speed: u8 = 40;
var slider_acceleration: u8 = 40;

const channel: mcl.Channel = .cc_link_1slot;

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var config: Config = undefined;

const Direction = enum(u1) {
    backward = 0,
    forward = 1,
};

pub const Config = struct {
    connection: Connection,
    /// Minimum delay between polls through MELSEC, in us.
    min_poll_rate: u64,
    drivers: []Driver,

    const Connection = enum(u8) {
        @"CC-Link Ver.2" = 0,
    };

    const Driver = struct {
        axis1: ?Axis,
        axis2: ?Axis,
        axis3: ?Axis,

        const Axis = struct {
            location: f32,
        };

        pub fn axis(self: Driver, axis_index: u2) ?Axis {
            return switch (axis_index) {
                0 => self.axis1,
                1 => self.axis2,
                2 => self.axis3,
                3 => unreachable,
            };
        }
    };
};

pub fn init(c: Config) !void {
    if (c.drivers.len == 0 or c.drivers.len > std.math.maxInt(u6) + 1) {
        return error.InvalidDriverConfiguration;
    }
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    allocator = arena.allocator();

    config = .{
        .connection = c.connection,
        .min_poll_rate = c.min_poll_rate,
        .drivers = try allocator.alloc(Config.Driver, c.drivers.len),
    };
    @memcpy(config.drivers, c.drivers);

    try command.registry.put("MCL_VERSION", .{
        .name = "MCL_VERSION",
        .short_description = "Display the version of MCL.",
        .long_description =
        \\Print the currently linked version of the PMF Motion Control Library
        \\in Semantic Version format.
        ,
        .execute = &mclVersion,
    });
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
    try command.registry.put("DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End MCL's connection with the motion system. This command should be
        \\run after other MCL commands are completed.
        ,
        .execute = &mclDisconnect,
    });
    try command.registry.put("SET_SPEED", .{
        .name = "SET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "speed percentage" },
        },
        .short_description = "Set the speed of slider movement.",
        .long_description =
        \\Set the speed of slider movement. This must be a whole integer number
        \\between 1 and 100, inclusive.
        ,
        .execute = &mclSetSpeed,
    });
    try command.registry.put("SET_ACCELERATION", .{
        .name = "SET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "acceleration percentage" },
        },
        .short_description = "Set the acceleration of slider movement.",
        .long_description =
        \\Set the acceleration of slider movement. This must be a whole integer
        \\number between 1 and 100, inclusive.
        ,
        .execute = &mclSetAcceleration,
    });
    try command.registry.put("AXIS_SLIDER", .{
        .name = "AXIS_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "axis" },
            .{ .name = "result variable", .optional = true, .resolve = false },
        },
        .short_description = "Display slider on given axis.",
        .long_description =
        \\If a slider is recognized by the provided axis, print its slider ID.
        \\If a result variable name was provided, also store the slider ID in
        \\the variable.
        ,
        .execute = &mclAxisSlider,
    });
    try command.registry.put("RELEASE_AXIS_SERVO", .{
        .name = "RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{.{ .name = "axis" }},
        .short_description = "Release the servo of a given axis.",
        .long_description =
        \\Release the servo of a given axis, allowing for free slider movement.
        \\This command should be run before sliders move within or exit from
        \\the system due to external influence.
        ,
        .execute = &mclAxisReleaseServo,
    });
    try command.registry.put("WAIT_RELEASE_AXIS_SERVO", .{
        .name = "WAIT_RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{.{ .name = "axis" }},
        .short_description = "Wait until a given axis has released its servo.",
        .long_description =
        \\Pause the execution of any further commands until the given axis has
        \\indicated that it has released its servo.
        ,
        .execute = &mclAxisWaitReleaseServo,
    });
    try command.registry.put("HOME_SLIDER", .{
        .name = "HOME_SLIDER",
        .short_description = "Home an unrecognized slider on the first axis.",
        .long_description =
        \\Home an unrecognized slider on the first axis. The unrecognized
        \\slider must be positioned in the correct homing position.
        ,
        .execute = &mclHomeSlider,
    });
    try command.registry.put("WAIT_HOME_SLIDER", .{
        .name = "WAIT_HOME_SLIDER",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("RECOVER_SLIDER", .{
        .name = "RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("WAIT_RECOVER_SLIDER", .{
        .name = "WAIT_RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("SLIDER_LOCATION", .{
        .name = "SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "slider" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Display a slider's location.",
        .long_description =
        \\Print a given slider's location if it is currently recognized in the
        \\motion system. If a result variable name is provided, then store the
        \\slider's location in the variable.
        ,
        .execute = &mclSliderLocation,
    });
    try command.registry.put("MOVE_SLIDER_AXIS", .{
        .name = "MOVE_SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("MOVE_SLIDER_LOCATION", .{
        .name = "MOVE_SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("MOVE_SLIDER_DISTANCE", .{
        .name = "MOVE_SLIDER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
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
    try command.registry.put("WAIT_MOVE_SLIDER", .{
        .name = "WAIT_MOVE_SLIDER",
        .parameters = &[_]command.Command.Parameter{.{ .name = "slider" }},
        .short_description = "Wait for slider movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given slider is indicated as complete.
        ,
        .execute = &mclWaitMoveSlider,
    });
}

pub fn deinit() void {
    arena.deinit();
}

fn mclVersion(_: [][]const u8) !void {
    std.log.info("MCL Version: {d}.{d}.{d}\n", .{
        mcl.version().major,
        mcl.version().minor,
        mcl.version().patch,
    });
}

fn mclConnect(_: [][]const u8) !void {
    try mcl.openChannel(channel);
    errdefer mcl.closeChannel(channel) catch {};

    var station_index: u6 = 0;
    for (config.drivers) |_| {
        const y: *mcl.Station.Y = try mcl.getStationY(channel, station_index);
        y.*.cc_link_enable = true;
        station_index += 1;
    }
    errdefer disconnect() catch {};
    try mcl.sendChannelY(channel, 0, @truncate(config.drivers.len - 1));
}

fn disconnect() !void {
    var station_index: u6 = 0;
    for (config.drivers) |_| {
        const y: *mcl.Station.Y = try mcl.getStationY(channel, station_index);
        y.*.cc_link_enable = false;
        station_index += 1;
    }
    try mcl.sendChannelY(channel, 0, @truncate(config.drivers.len - 1));
    try mcl.closeChannel(channel);
}

fn mclDisconnect(_: [][]const u8) !void {
    try disconnect();
}

fn mclAxisSlider(params: [][]const u8) !void {
    const axis_id = try std.fmt.parseInt(i16, params[0], 0);
    var slider: ?i16 = null;

    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len));
    var axis_counter: i16 = 0;
    driver_loop: for (config.drivers, 0..) |driver, _station_index| {
        const station_index: u6 = @intCast(_station_index);
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i)) |_| {
                axis_counter += 1;
                if (axis_counter == axis_id) {
                    const wr: *mcl.Station.Wr = try mcl.getStationWr(
                        channel,
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
    }
    if (slider) |slider_id| {
        std.log.info("Slider {d} on axis {d}.\n", .{ slider_id, axis_id });
        if (params[1].len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                params[1],
                try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
            );
        }
    } else {
        std.log.info("No slider recognized on axis {d}.\n", .{axis_id});
    }
}

fn mclAxisReleaseServo(params: [][]const u8) !void {
    const axis_id: i16 = try std.fmt.parseInt(i16, params[0], 0);
    var axis_counter: i16 = 0;
    var station_index: u6 = 0;
    driver_loop: for (config.drivers) |driver| {
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i)) |_| {
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

    const ww: *mcl.Station.Ww = try mcl.getStationWw(
        channel,
        station_index,
    );
    const x: *mcl.Station.X = try mcl.getStationX(
        channel,
        station_index,
    );
    ww.*.target_axis_number = axis_id;
    try mcl.sendStationWw(channel, station_index);
    try mcl.setStationY(
        channel,
        station_index,
        0x5,
    );
    // Reset on error as well as on success.
    defer mcl.resetStationY(channel, station_index, 0x5) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollStation(channel, station_index);
        if (!x.servoActive(@intCast(axis_counter))) break;
    }
}

fn mclAxisWaitReleaseServo(params: [][]const u8) !void {
    const axis_id: i16 = try std.fmt.parseInt(i16, params[0], 0);

    var axis_counter: i16 = 0;
    var station_index: u6 = 0;
    driver_loop: for (config.drivers) |driver| {
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i)) |_| {
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

    const x: *mcl.Station.X = try mcl.getStationX(
        channel,
        station_index,
    );
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollStation(channel, station_index);
        if (x.servoActive(@intCast(axis_counter))) return;
    }
}

fn mclHomeSlider(_: [][]const u8) !void {
    try waitCommandReady(channel, 0);
    const ww: *mcl.Station.Ww = try mcl.getStationWw(channel, 0);
    ww.*.command_code = .Home;
    try sendCommand(channel, 0);
}

fn mclWaitHomeSlider(params: [][]const u8) !void {
    const wr: *mcl.Station.Wr = try mcl.getStationWr(channel, 0);
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollStation(channel, 0);

        const slider: ?i16 = if (wr.slider_number.axis1 != 0)
            wr.slider_number.axis1
        else
            null;

        if (slider) |slider_id| {
            std.log.info("Slider {d} homed.\n", .{slider_id});
            if (params[0].len > 0) {
                var int_buf: [8]u8 = undefined;
                try command.variables.put(
                    params[0],
                    try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
                );
            }
            break;
        }
    }
}

fn mclSetSpeed(params: [][]const u8) !void {
    const _slider_speed = try std.fmt.parseUnsigned(u8, params[0], 0);
    if (_slider_speed == 0 or _slider_speed > 100) return error.InvalidSpeed;
    slider_speed = _slider_speed;
}

fn mclSetAcceleration(params: [][]const u8) !void {
    const _slider_acceleration = try std.fmt.parseUnsigned(u8, params[0], 0);
    if (_slider_acceleration == 0 or _slider_acceleration > 100)
        return error.InvalidAcceleration;
    slider_acceleration = _slider_acceleration;
}

fn mclSliderLocation(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(i16, params[0], 0);
    if (slider_id == 0) return error.InvalidSliderId;
    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

    var station_index: u6 = 0;
    var location: mcl.Station.Distance = .{};
    driver_loop: for (config.drivers) |driver| {
        const wr: *mcl.Station.Wr = try mcl.getStationWr(
            channel,
            station_index,
        );
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i) != null and wr.sliderNumber(i) == slider_id) {
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
    if (params[1].len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(params[1], try std.fmt.bufPrint(
            &float_buf,
            "{d}.{d}",
            .{ location.mm, location.um },
        ));
    }
}

fn mclSliderPosMoveAxis(params: [][]const u8) !void {
    const slider_id: i16 = try std.fmt.parseInt(i16, params[0], 0);
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);
    if (slider_id == 0) return error.InvalidSliderId;

    std.log.debug("Polling CC-Link...", .{});
    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

    var station_index: u6 = 0;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;
    // Find station and axis of slider.
    std.log.debug("Parsing drivers...", .{});
    driver_loop: for (config.drivers) |driver| {
        const wr: *mcl.Station.Wr = try mcl.getStationWr(
            channel,
            station_index,
        );
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i) != null and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axis(j)) |_| {
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
    if (last_axis and station_index < config.drivers.len - 1) {
        std.log.debug("Checking transmission stop conditions...", .{});
        const next_station_index: u6 = station_index + 1;
        const next_wr: *mcl.Station.Wr = try mcl.getStationWr(
            channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (config.drivers[next_station_index].axis(i)) |_| {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Destination axis is at or beyond next driver.
                    // Forward movement.
                    if (axis_id > axis_index + 1) {
                        try stopTrafficTransmission(
                            channel,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Destination is at or before current driver.
                    // Backward movement.
                    else {
                        try stopTrafficTransmission(
                            channel,
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

    const ww: *mcl.Station.Ww = try mcl.getStationWw(channel, station_index);
    std.log.debug("Waiting for command ready state...", .{});
    try waitCommandReady(channel, station_index);
    ww.*.command_code = .MoveSliderToAxisByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.target_axis_number = axis_id;
    ww.*.speed_percentage = slider_speed;
    ww.*.acceleration_percentage = slider_acceleration;
    std.log.debug("Sending command...", .{});
    try sendCommand(channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(channel, station_index, dir);
    }
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const slider_id: i16 = try std.fmt.parseInt(i16, params[0], 0);
    const location_float: f32 = try std.fmt.parseFloat(f32, params[1]);
    if (slider_id == 0) return error.InvalidSliderId;

    const location: mcl.Station.Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

    var station_index: u6 = 0;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;

    var wr: *mcl.Station.Wr = undefined;
    // Find station and axis of slider.
    driver_loop: for (config.drivers) |driver| {
        wr = try mcl.getStationWr(channel, station_index);
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i) != null and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axis(j)) |_| {
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
    if (last_axis and station_index < config.drivers.len - 1) {
        const next_station_index: u6 = station_index + 1;
        const next_wr: *mcl.Station.Wr = try mcl.getStationWr(
            channel,
            next_station_index,
        );
        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (config.drivers[next_station_index].axis(i)) |_| {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Destination location is in front of current location.
                    // Forward movement.
                    if (location.mm > wr.sliderLocation(i).mm or
                        (location.mm == wr.sliderLocation(i).mm and
                        location.um > wr.sliderLocation(i).um))
                    {
                        try stopTrafficTransmission(
                            channel,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Destination location is behind current location.
                    // Backward movement.
                    else {
                        try stopTrafficTransmission(
                            channel,
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

    const ww: *mcl.Station.Ww = try mcl.getStationWw(channel, station_index);
    try waitCommandReady(channel, station_index);
    ww.*.command_code = .MoveSliderToLocationByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.location_distance = location;
    ww.*.speed_percentage = slider_speed;
    ww.*.acceleration_percentage = slider_acceleration;
    try sendCommand(channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(channel, station_index, dir);
    }
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(i16, params[0], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[1]);
    if (slider_id == 0) return error.InvalidSliderId;

    const distance: mcl.Station.Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

    var station_index: u6 = 0;
    // Index of axis in system.
    var axis_index: i16 = 0;
    // Local index of axis per station.
    var station_axis_index: u2 = undefined;
    // Whether axis is last axis in station.
    var last_axis: bool = false;

    var wr: *mcl.Station.Wr = undefined;
    // Find station and axis of slider.
    driver_loop: for (config.drivers) |driver| {
        wr = try mcl.getStationWr(channel, station_index);
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i) != null and wr.sliderNumber(i) == slider_id) {
                station_axis_index = i;
                // Check if axis is last valid in driver.
                for ((_i + 1)..3) |_j| {
                    const j: u2 = @intCast(_j);
                    if (driver.axis(j)) |_| {
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
    if (last_axis and station_index < config.drivers.len - 1) {
        const next_station_index: u6 = station_index + 1;
        const next_wr: *mcl.Station.Wr = try mcl.getStationWr(
            channel,
            next_station_index,
        );

        // Check first axis of next driver to see if slider is between drivers.
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (config.drivers[next_station_index].axis(i)) |_| {
                if (next_wr.sliderNumber(i) == slider_id) {
                    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                    // Distance is positive. Forward movement.
                    if (distance.mm > 0 or
                        (distance.mm == 0 and distance.um > 0))
                    {
                        try stopTrafficTransmission(
                            channel,
                            station_index,
                            .forward,
                        );
                        stopped_transmission = .forward;
                    }
                    // Distance is negative or 0. Backward movement.
                    else {
                        try stopTrafficTransmission(
                            channel,
                            station_index,
                            .backward,
                        );
                        stopped_transmission = .backward;
                    }
                }
            }
        }
    }

    const ww: *mcl.Station.Ww = try mcl.getStationWw(channel, station_index);
    try waitCommandReady(channel, station_index);
    ww.*.command_code = .MoveSliderDistanceByPosition;
    ww.*.command_slider_number = slider_id;
    ww.*.location_distance = distance;
    ww.*.speed_percentage = slider_speed;
    ww.*.acceleration_percentage = slider_acceleration;
    try sendCommand(channel, station_index);

    if (stopped_transmission) |dir| {
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try restartTrafficTransmission(channel, station_index, dir);
    }
}

fn mclWaitMoveSlider(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(i16, params[0], 0);
    if (slider_id == 0) return error.InvalidSliderId;

    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

        var station_index: u6 = 0;
        var slider_id_found: bool = false;
        for (config.drivers) |driver| {
            try command.checkCommandInterrupt();
            const wr: *mcl.Station.Wr = try mcl.getStationWr(
                channel,
                station_index,
            );
            for (0..3) |_i| {
                const i: u2 = @intCast(_i);
                if (driver.axis(i) != null and
                    wr.sliderNumber(i) == slider_id)
                {
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
    const axis: i16 = try std.fmt.parseUnsigned(i16, params[0], 0);
    const new_slider_id: i16 = try std.fmt.parseUnsigned(i16, params[1], 0);
    if (new_slider_id < 1 or new_slider_id > 127) return error.InvalidSliderID;

    std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
    try mcl.pollChannel(channel, 0, @truncate(config.drivers.len - 1));

    var axis_counter: i16 = 0;
    var station_index: u6 = 0;
    driver_loop: for (config.drivers) |driver| {
        try command.checkCommandInterrupt();
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i)) |_| {
                axis_counter += 1;
                if (axis_counter == axis) {
                    // Slider recovery requires local driver axis ID (1-3).
                    axis_counter = i + 1;
                    break :driver_loop;
                }
            }
        }
        station_index += 1;
    } else {
        return error.TargetAxisNotFound;
    }

    const ww: *mcl.Station.Ww = try mcl.getStationWw(channel, station_index);

    try waitCommandReady(channel, station_index);
    ww.*.command_code = .RecoverSliderAtAxis;
    ww.*.target_axis_number = axis_counter;
    ww.*.command_slider_number = new_slider_id;
    try sendCommand(channel, station_index);
}

fn mclWaitRecoverSlider(params: [][]const u8) !void {
    const axis: i16 = try std.fmt.parseUnsigned(i16, params[0], 0);
    var slider_id: i16 = undefined;

    var axis_counter: i16 = 0;
    var station_index: u6 = 0;
    driver_search: for (config.drivers) |driver| {
        try command.checkCommandInterrupt();
        for (0..3) |_i| {
            const i: u2 = @intCast(_i);
            if (driver.axis(i)) |_| {
                axis_counter += 1;
                if (axis_counter == axis) {
                    const wr: *mcl.Station.Wr = try mcl.getStationWr(
                        channel,
                        station_index,
                    );
                    while (true) {
                        try command.checkCommandInterrupt();
                        std.time.sleep(
                            std.time.ns_per_us * config.min_poll_rate,
                        );
                        try mcl.pollStation(channel, station_index);

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
    if (params[0].len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            params[0],
            try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
        );
    }
}

fn waitCommandReady(c: mcl.Channel, station_index: u6) !void {
    const x: *mcl.Station.X = try mcl.getStationX(c, station_index);
    std.log.debug("Waiting for command ready state...", .{});
    while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollStation(c, station_index);
        if (x.ready_for_command) break;
    }
}

fn sendCommand(c: mcl.Channel, station_index: u6) !void {
    const x: *mcl.Station.X = try mcl.getStationX(c, station_index);

    std.log.debug("Sending command...", .{});
    try mcl.sendStationWw(c, station_index);
    try mcl.setStationY(c, station_index, 0x2);
    send_command: while (true) {
        try command.checkCommandInterrupt();
        std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
        try mcl.pollStation(c, station_index);
        if (x.command_received) {
            std.log.debug("Resetting command received flag...", .{});
            try mcl.resetStationY(c, station_index, 0x2);
            try mcl.setStationY(c, station_index, 0x3);
            reset_received: while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index);
                if (!x.command_received) {
                    try mcl.resetStationY(c, station_index, 0x3);
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
    c: mcl.Channel,
    station_index: u6,
    direction: Direction,
) !void {
    if (station_index >= config.drivers.len) return;
    std.log.debug("Stopping traffic transmission...", .{});

    const station: mcl.StationReference = try mcl.getStation(c, station_index);
    const next_station: mcl.StationReference = try mcl.getStation(
        c,
        station_index + 1,
    );

    var state: mcl.Station.Wr.SliderStateCode = undefined;
    var next_state: mcl.Station.Wr.SliderStateCode = undefined;

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (config.drivers[station_index].axis(2 - i)) |_| {
            state = station.wr.sliderState(2 - i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (config.drivers[station_index + 1].axis(i)) |_| {
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
            try mcl.setStationY(c, station_index - 1, 0xA);
            const prev_x: *mcl.Station.X = try mcl.getStationX(
                c,
                station_index - 1,
            );
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index - 1);
                if (prev_x.transmission_stopped.from_next) {
                    break;
                }
            }
        } else if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted)
        {
            // Stop traffic transmission from previous station to current
            // station.
            try mcl.setStationY(c, station_index, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index);
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
            try mcl.setStationY(c, station_index + 1, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index + 1);
                if (next_station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        } else if (next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted or
            next_state == .None)
        {
            // Stop traffic transmission from next station to current station.
            try mcl.setStationY(c, station_index, 0xA);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index);
                if (station.x.transmission_stopped.from_next) {
                    break;
                }
            }
        }
    }
}

/// Handle traffic transmission start after slider movement command.
fn restartTrafficTransmission(
    c: mcl.Channel,
    station_index: u6,
    direction: Direction,
) !void {
    if (station_index >= config.drivers.len) return;
    std.log.debug("Restarting traffic transmission...", .{});

    const station: mcl.StationReference = try mcl.getStation(c, station_index);
    const next_station: mcl.StationReference = try mcl.getStation(
        c,
        station_index + 1,
    );

    var state: mcl.Station.Wr.SliderStateCode = undefined;
    var next_state: mcl.Station.Wr.SliderStateCode = undefined;

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (config.drivers[station_index].axis(2 - i)) |_| {
            state = station.wr.sliderState(2 - i);
            break;
        }
    } else {
        return error.InvalidDriverConfiguration;
    }

    for (0..3) |_i| {
        const i: u2 = @intCast(_i);
        if (config.drivers[station_index + 1].axis(i)) |_| {
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
            try mcl.resetStationY(c, station_index - 1, 0xA);
            const prev_x: *mcl.Station.X = try mcl.getStationX(
                c,
                station_index - 1,
            );
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index - 1);
                if (!prev_x.transmission_stopped.from_next) {
                    break;
                }
            }
        } else if (state == .NextAxisAuxiliary or
            state == .NextAxisCompleted)
        {
            // Start traffic transmission from previous station to current
            // station.
            try mcl.resetStationY(c, station_index, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index);
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
            try mcl.resetStationY(c, station_index + 1, 0x9);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index + 1);
                if (!next_station.x.transmission_stopped.from_prev) {
                    break;
                }
            }
        } else if (next_state == .PrevAxisAuxiliary or
            next_state == .PrevAxisCompleted or
            next_state == .None)
        {
            // Start traffic transmission from next station to current station.
            try mcl.resetStationY(c, station_index, 0xA);
            while (true) {
                try command.checkCommandInterrupt();
                std.time.sleep(std.time.ns_per_us * config.min_poll_rate);
                try mcl.pollStation(c, station_index);
                if (!station.x.transmission_stopped.from_next) {
                    break;
                }
            }
        }
    }
}
