const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");

var slider_speed: u8 = 40;
var slider_acceleration: u8 = 40;

pub const Config = struct {
    connection: Connection,
    min_poll_rate: c_ulong,
    drivers: []Driver,

    const Connection = enum(u8) {
        @"CC-Link Ver.2" = 0,
    };

    const Driver = struct {
        axis_1: ?Axis,
        axis_2: ?Axis,
        axis_3: ?Axis,

        const Axis = struct {
            location: f32,
        };
    };
};

pub fn init(config: Config) !void {
    if (config.drivers.len == 0) {
        return error.InvalidDriverConfiguration;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = arena.allocator();
    var drivers: []mcl.DriverConfig = try allocator.alloc(
        mcl.DriverConfig,
        config.drivers.len,
    );
    defer allocator.free(drivers);

    for (config.drivers, 0..) |d, i| {
        drivers[i] = .{
            .axis1 = null,
            .axis2 = null,
            .axis3 = null,
        };
        if (d.axis_1) |a| {
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis1 = .{
                .position = .{ .mm = mm, .um = um },
            };
        }
        if (d.axis_2) |a| {
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis2 = .{
                .position = .{ .mm = mm, .um = um },
            };
        }
        if (d.axis_3) |a| {
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis3 = .{
                .position = .{ .mm = mm, .um = um },
            };
        }
    }

    const mcl_conf: mcl.Config = .{
        .connection_kind = switch (config.connection) {
            .@"CC-Link Ver.2" => .CcLinkVer2,
        },
        .connection_min_polling_interval = config.min_poll_rate,
        .drivers = drivers,
    };

    try mcl.init(mcl_conf);

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
    mcl.deinit();
}

fn mclVersion(_: [][]const u8) !void {
    std.log.info("MCL Version: {d}.{d}.{d}\n", .{
        mcl.version().major,
        mcl.version().minor,
        mcl.version().patch,
    });
}

fn mclConnect(_: [][]const u8) !void {
    try mcl.connect();
}

fn mclDisconnect(_: [][]const u8) !void {
    try mcl.disconnect();
}

fn mclAxisSlider(params: [][]const u8) !void {
    const axis_id = try std.fmt.parseInt(mcl.AxisId, params[0], 0);

    try mcl.poll();
    const slider = mcl.axisSlider(axis_id);
    try mcl.poll();

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
    try mcl.poll();
    try mcl.axisServoRelease(
        try std.fmt.parseInt(mcl.AxisId, params[0], 0),
    );
    try mcl.poll();
}

fn mclAxisWaitReleaseServo(params: [][]const u8) !void {
    while (true) {
        try command.checkCommandInterrupt();
        try mcl.poll();
        const released: bool = mcl.axisServoReleased(
            try std.fmt.parseInt(mcl.AxisId, params[0], 0),
        );
        try mcl.poll();
        if (released) break;
    }
}

fn mclHomeSlider(_: [][]const u8) !void {
    try mcl.poll();
    try mcl.home();
    try mcl.poll();
}

fn mclWaitHomeSlider(params: [][]const u8) !void {
    while (true) {
        try command.checkCommandInterrupt();
        try mcl.poll();
        const slider = mcl.axisSlider(1);
        try mcl.poll();
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
    const slider_id = try std.fmt.parseInt(mcl.SliderId, params[0], 0);
    try mcl.poll();
    const location: mcl.Distance = try mcl.sliderLocation(slider_id);
    try mcl.poll();
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
    const slider_id = try std.fmt.parseInt(mcl.SliderId, params[0], 0);
    const axis_id = try std.fmt.parseInt(mcl.AxisId, params[1], 0);
    try mcl.poll();
    try mcl.sliderPosMoveAxis(
        slider_id,
        axis_id,
        slider_speed,
        slider_acceleration,
    );
    try mcl.poll();
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(mcl.SliderId, params[0], 0);
    const location_float = try std.fmt.parseFloat(f32, params[1]);
    const location: mcl.Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };
    try mcl.poll();
    try mcl.sliderPosMoveLocation(
        slider_id,
        location,
        slider_speed,
        slider_acceleration,
    );
    try mcl.poll();
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(mcl.SliderId, params[0], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[1]);
    const distance: mcl.Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };
    try mcl.poll();
    try mcl.sliderPosMoveDistance(
        slider_id,
        distance,
        slider_speed,
        slider_acceleration,
    );
    try mcl.poll();
}

fn mclWaitMoveSlider(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(mcl.SliderId, params[0], 0);
    var completed: bool = false;
    while (!completed) {
        try command.checkCommandInterrupt();
        try mcl.poll();
        completed = try mcl.sliderPosMoveCompleted(slider_id);
        try mcl.poll();
    }
}

fn mclRecoverSlider(params: [][]const u8) !void {
    const axis = try std.fmt.parseUnsigned(mcl.AxisId, params[0], 0);
    const new_slider_id = try std.fmt.parseUnsigned(
        mcl.SliderId,
        params[1],
        0,
    );
    if (new_slider_id < 1 or new_slider_id > 127) return error.InvalidSliderID;
    try mcl.poll();
    try mcl.axisRecoverSlider(axis, new_slider_id);
    try mcl.poll();
}

fn mclWaitRecoverSlider(params: [][]const u8) !void {
    const axis = try std.fmt.parseUnsigned(mcl.AxisId, params[0], 0);
    while (true) {
        try command.checkCommandInterrupt();
        try mcl.poll();
        const slider = mcl.axisSlider(axis);
        try mcl.poll();
        if (slider) |slider_id| {
            std.log.info("Slider {d} recovered.\n", .{slider_id});
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
