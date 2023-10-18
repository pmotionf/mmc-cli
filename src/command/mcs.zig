const std = @import("std");
const c = @cImport(@cInclude("MCS.h"));
const command = @import("../command.zig");

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
    var drivers: []c.McsDriverConfig = try allocator.alloc(
        c.McsDriverConfig,
        config.drivers.len,
    );
    defer allocator.free(drivers);

    for (config.drivers, 0..) |d, i| {
        drivers[i] = .{
            .using_axis1 = 0,
            .axis1_position = .{ .mm = 0, .um = 0 },
            .using_axis2 = 0,
            .axis2_position = .{ .mm = 0, .um = 0 },
            .using_axis3 = 0,
            .axis3_position = .{ .mm = 0, .um = 0 },
        };
        if (d.axis_1) |a| {
            drivers[i].using_axis1 = 1;
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis1_position = .{ .mm = mm, .um = um };
        }
        if (d.axis_2) |a| {
            drivers[i].using_axis2 = 1;
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis2_position = .{ .mm = mm, .um = um };
        }
        if (d.axis_3) |a| {
            drivers[i].using_axis3 = 1;
            const mm: c_short = @intFromFloat(a.location);
            const um: c_short = @intFromFloat(
                1000 * (a.location - @trunc(a.location)),
            );
            drivers[i].axis3_position = .{ .mm = mm, .um = um };
        }
    }

    const mcs_conf: c.McsConfig = .{
        .connection_kind = @intFromEnum(config.connection),
        .connection_min_polling_interval = config.min_poll_rate,
        .num_drivers = @intCast(config.drivers.len),
        .drivers = @ptrCast((&drivers).ptr),
    };
    try mcsError(c.mcsInit(&mcs_conf));
    try command.registry.put("MCS_VERSION", .{
        .name = "MCS_VERSION",
        .short_description = "Display the version of the MCS library.",
        .long_description =
        \\Print the currently linked version of the Motion Control Software
        \\library in Semantic Version format.
        ,
        .execute = &mcsVersion,
    });
    try command.registry.put("CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect MCS library with motion system.",
        .long_description =
        \\Initialize the MCS library's connection with the motion system. This
        \\command should be run before any other MCS command, and also after
        \\any power cycle of the motion system.
        ,
        .execute = &mcsConnect,
    });
    try command.registry.put("DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCS library from motion system.",
        .long_description =
        \\End the MCS library's connection with the motion system. This command
        \\should be run after other MCS commands are completed.
        ,
        .execute = &mcsDisconnect,
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
        .execute = &mcsSetSpeed,
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
        .execute = &mcsSetAcceleration,
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
        .execute = &mcsAxisSlider,
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
        .execute = &mcsAxisReleaseServo,
    });
    try command.registry.put("WAIT_RELEASE_AXIS_SERVO", .{
        .name = "WAIT_RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{.{ .name = "axis" }},
        .short_description = "Wait until a given axis has released its servo.",
        .long_description =
        \\Pause the execution of any further commands until the given axis has
        \\indicated that it has released its servo.
        ,
        .execute = &mcsAxisWaitReleaseServo,
    });
    try command.registry.put("HOME_SLIDER", .{
        .name = "HOME_SLIDER",
        .short_description = "Home an unrecognized slider on the first axis.",
        .long_description =
        \\Home an unrecognized slider on the first axis. The unrecognized
        \\slider must be positioned in the correct homing position.
        ,
        .execute = &mcsHomeSlider,
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
        .execute = &mcsWaitHomeSlider,
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
        .execute = &mcsRecoverSlider,
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
        .execute = &mcsWaitRecoverSlider,
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
        .execute = &mcsSliderLocation,
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
        .execute = &mcsSliderPosMoveAxis,
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
        .execute = &mcsSliderPosMoveLocation,
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
        .execute = &mcsSliderPosMoveDistance,
    });
    try command.registry.put("WAIT_MOVE_SLIDER", .{
        .name = "WAIT_MOVE_SLIDER",
        .parameters = &[_]command.Command.Parameter{.{ .name = "slider" }},
        .short_description = "Wait for slider movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given slider is indicated as complete.
        ,
        .execute = &mcsWaitMoveSlider,
    });
}

pub fn deinit() void {
    c.mcsDeinit();
}

fn mcsError(code: c_int) !void {
    if (code != 0) {
        std.log.err("MCS Error: {s}", .{c.mcsErrorString(code)});
        return error.McsError;
    }
}

fn mcsVersion(_: [][]const u8) !void {
    std.log.info("MCS Version: {d}.{d}.{d}\n", .{
        c.mcsVersionMajor(),
        c.mcsVersionMinor(),
        c.mcsVersionPatch(),
    });
}

fn mcsConnect(_: [][]const u8) !void {
    try mcsError(c.mcsConnect());
}

fn mcsDisconnect(_: [][]const u8) !void {
    try mcsError(c.mcsDisconnect());
}

fn mcsAxisSlider(params: [][]const u8) !void {
    var slider_id: c.McsSliderId = 0;
    const axis_id = try std.fmt.parseInt(c.McsAxisId, params[0], 0);

    try mcsError(c.mcsPoll());
    c.mcsAxisSlider(axis_id, &slider_id);
    try mcsError(c.mcsPoll());

    if (slider_id == 0) {
        std.log.info("No slider recognized on axis {d}.\n", .{axis_id});
    } else {
        std.log.info("Slider {d} on axis {d}.\n", .{ slider_id, axis_id });
        if (params[1].len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                params[1],
                try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
            );
        }
    }
}

fn mcsAxisReleaseServo(params: [][]const u8) !void {
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsAxisServoRelease(
        try std.fmt.parseInt(c.McsAxisId, params[0], 0),
    ));
    try mcsError(c.mcsPoll());
}

fn mcsAxisWaitReleaseServo(params: [][]const u8) !void {
    var released: c_int = 0;
    while (true) {
        try command.checkCommandInterrupt();
        try mcsError(c.mcsPoll());
        c.mcsAxisServoReleased(
            try std.fmt.parseInt(c.McsAxisId, params[0], 0),
            &released,
        );
        try mcsError(c.mcsPoll());
        if (released != 0) break;
    }
}

fn mcsHomeSlider(_: [][]const u8) !void {
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsHome());
    try mcsError(c.mcsPoll());
}

fn mcsWaitHomeSlider(params: [][]const u8) !void {
    var slider_id: c.McsSliderId = 0;
    while (true) {
        try command.checkCommandInterrupt();
        try mcsError(c.mcsPoll());
        c.mcsAxisSlider(1, &slider_id);
        try mcsError(c.mcsPoll());
        if (slider_id != 0) {
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

fn mcsSetSpeed(params: [][]const u8) !void {
    const _slider_speed = try std.fmt.parseUnsigned(u8, params[0], 0);
    if (_slider_speed == 0 or _slider_speed > 100) return error.InvalidSpeed;
    slider_speed = _slider_speed;
}

fn mcsSetAcceleration(params: [][]const u8) !void {
    const _slider_acceleration = try std.fmt.parseUnsigned(u8, params[0], 0);
    if (_slider_acceleration == 0 or _slider_acceleration > 100)
        return error.InvalidAcceleration;
    slider_acceleration = _slider_acceleration;
}

fn mcsSliderLocation(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(c.McsSliderId, params[0], 0);
    var location: c.McsDistance = .{ .mm = 0, .um = 0 };
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsSliderLocation(slider_id, &location));
    try mcsError(c.mcsPoll());
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

fn mcsSliderPosMoveAxis(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(c.McsSliderId, params[0], 0);
    const axis_id = try std.fmt.parseInt(c.McsAxisId, params[1], 0);
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsSliderPosMoveAxis(
        slider_id,
        axis_id,
        slider_speed,
        slider_acceleration,
    ));
    try mcsError(c.mcsPoll());
}

fn mcsSliderPosMoveLocation(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(c.McsSliderId, params[0], 0);
    const location_float = try std.fmt.parseFloat(f32, params[1]);
    const location: c.McsDistance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsSliderPosMoveLocation(
        slider_id,
        location,
        slider_speed,
        slider_acceleration,
    ));
    try mcsError(c.mcsPoll());
}

fn mcsSliderPosMoveDistance(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(c.McsSliderId, params[0], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[1]);
    const distance: c.McsDistance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsSliderPosMoveDistance(
        slider_id,
        distance,
        slider_speed,
        slider_acceleration,
    ));
    try mcsError(c.mcsPoll());
}

fn mcsWaitMoveSlider(params: [][]const u8) !void {
    const slider_id = try std.fmt.parseInt(c.McsSliderId, params[0], 0);
    var completed: c_int = 0;
    while (completed == 0) {
        try command.checkCommandInterrupt();
        try mcsError(c.mcsPoll());
        try mcsError(c.mcsSliderPosMoveCompleted(slider_id, &completed));
        try mcsError(c.mcsPoll());
    }
}

fn mcsRecoverSlider(params: [][]const u8) !void {
    const axis = try std.fmt.parseUnsigned(c.McsAxisId, params[0], 0);
    const new_slider_id = try std.fmt.parseUnsigned(
        c.McsSliderId,
        params[1],
        0,
    );
    if (new_slider_id < 1 or new_slider_id > 127) return error.InvalidSliderID;
    try mcsError(c.mcsPoll());
    try mcsError(c.mcsAxisRecoverSlider(axis, new_slider_id));
    try mcsError(c.mcsPoll());
}

fn mcsWaitRecoverSlider(params: [][]const u8) !void {
    const axis = try std.fmt.parseUnsigned(c.McsAxisId, params[0], 0);
    var slider_id: c.McsSliderId = 0;
    while (true) {
        try command.checkCommandInterrupt();
        try mcsError(c.mcsPoll());
        c.mcsAxisSlider(axis, &slider_id);
        try mcsError(c.mcsPoll());
        if (slider_id != 0) {
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
