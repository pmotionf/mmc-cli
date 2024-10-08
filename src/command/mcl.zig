const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u7 = undefined;
var line_accelerations: []u7 = undefined;

const Direction = mcl.Direction;
const Station = mcl.Station;

pub const Config = struct {
    line_names: [][]const u8,
    lines: []mcl.Config.Line,
};

pub fn init(c: Config) !void {
    if (c.lines.len != c.line_names.len) {
        return error.ConfigLineNumberOfLineNamesDoesNotMatch;
    }

    try mcl.Config.validate(.{ .lines = c.lines });

    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    try mcl.init(allocator, .{ .lines = c.lines });

    line_names = try allocator.alloc([]u8, c.line_names.len);
    line_speeds = try allocator.alloc(u7, c.lines.len);
    line_accelerations = try allocator.alloc(u7, c.lines.len);
    for (0..c.lines.len) |i| {
        line_names[i] = try allocator.alloc(u8, c.line_names[i].len);
        @memcpy(line_names[i], c.line_names[i]);
        line_speeds[i] = 40;
        line_accelerations[i] = 40;
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
    try command.registry.put("GET_SPEED", .{
        .name = "GET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the speed of slider movement for a line.",
        .long_description =
        \\Get the speed of slider movement for a line. The line is referenced
        \\by its name. The speed is a whole integer number between 1 and 100,
        \\inclusive.
        ,
        .execute = &mclGetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("GET_SPEED");
    try command.registry.put("GET_ACCELERATION", .{
        .name = "GET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the acceleration of slider movement.",
        .long_description =
        \\Get the acceleration of slider movement for a line. The line is
        \\referenced by its name. The acceleration is a whole integer number
        \\between 1 and 100, inclusive.
        ,
        .execute = &mclGetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put("PRINT_X", .{
        .name = "PRINT_X",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the X register of a station.",
        .long_description =
        \\Poll and print the X register of a station. The station X register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &mclStationX,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_X");
    try command.registry.put("PRINT_Y", .{
        .name = "PRINT_Y",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Y register of a station.",
        .long_description =
        \\Poll and print the Y register of a station. The station Y register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &mclStationY,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_Y");
    try command.registry.put("PRINT_WR", .{
        .name = "PRINT_WR",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Wr register of a station.",
        .long_description =
        \\Poll and print the Wr register of a station. The station Wr register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &mclStationWr,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_WR");
    try command.registry.put("PRINT_WW", .{
        .name = "PRINT_WW",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Ww register of a station.",
        .long_description =
        \\Poll and print the Ww register of a station. The station Ww register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &mclStationWw,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_WW");
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
    try command.registry.put("SLIDER_AXIS", .{
        .name = "SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Display a slider's axis/axes.",
        .long_description =
        \\Print a given slider's axis if it is currently recognized in the
        \\provided line. If the slider is currently recognized across two axes,
        \\then both axes will be printed.
        ,
        .execute = &mclSliderAxis,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_AXIS");
    try command.registry.put("HALL_STATUS", .{
        .name = "HALL_STATUS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Display currently active hall sensors.",
        .long_description =
        \\List all active hall sensors. If an axis is provided, only hall
        \\sensors in that axis will be listed. Otherwise, all active hall
        \\sensors in the line will be listed.
        ,
        .execute = &mclHallStatus,
    });
    errdefer _ = command.registry.orderedRemove("HALL_STATUS");
    try command.registry.put("ASSERT_HALL", .{
        .name = "ASSERT_HALL",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "side" },
            .{ .name = "on/off", .optional = true },
        },
        .short_description = "Check that a hall alarm is the expected state.",
        .long_description =
        \\Throw an error if a hall alarm is not in the specified state. Must
        \\identify the hall alarm with line name, axis, and a side ("back" or
        \\"front"). Can optionally specify the expected hall alarm state as
        \\"off" or "on"; if not specified, will default to "on".
        ,
        .execute = &mclAssertHall,
    });
    errdefer _ = command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put("CLEAR_ERRORS", .{
        .name = "CLEAR_ERRORS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Clear driver errors of specified axis.",
        .long_description =
        \\Clear driver errors of specified axis.
        ,
        .execute = &mclClearErrors,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put("CLEAR_SLIDER_INFO", .{
        .name = "CLEAR_SLIDER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Clear slider information at specified axis.",
        .long_description =
        \\Clear slider information at specified axis.
        ,
        .execute = &mclClearSliderInfo,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_SLIDER_INFO");
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
    try command.registry.put("STOP_TRAFFIC", .{
        .name = "STOP_TRAFFIC",
        .parameters = &.{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
        },
        .short_description = "Prevent traffic communication to controller.",
        .long_description =
        \\Forcibly stop all traffic transmission from the specified axis's
        \\controller to its neighboring controller. The neighboring controller
        \\is determined by the provided direction.
        ,
        .execute = &mclTrafficStop,
    });
    errdefer _ = command.registry.orderedRemove("STOP_TRAFFIC");
    try command.registry.put("ALLOW_TRAFFIC", .{
        .name = "ALLOW_TRAFFIC",
        .parameters = &.{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
        },
        .short_description = "Resume traffic communication to controller.",
        .long_description =
        \\Permit all traffic transmission from the specified axis's controller
        \\to its neighboring controller. The neighboring controller is
        \\determined by the provided direction.
        ,
        .execute = &mclTrafficAllow,
    });
    errdefer _ = command.registry.orderedRemove("ALLOW_TRAFFIC");
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
    try command.registry.put("SET_LINE_ZERO", .{
        .name = "SET_LINE_ZERO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Set line zero position.",
        .long_description =
        \\Set a system line's zero position based on a current slider's 
        \\position. Aforementioned slider must be located at first axis of
        \\system line. 
        ,
        .execute = &setLineZero,
    });
    errdefer _ = command.registry.orderedRemove("SET_LINE_ZERO");
    try command.registry.put("ISOLATE", .{
        .name = "ISOLATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
            .{ .name = "slider id", .optional = true },
            .{ .name = "link axis", .resolve = false, .optional = true },
        },
        .short_description = "Isolate an uninitialized slider backwards.",
        .long_description =
        \\Slowly move an uninitialized slider to separate it from other nearby
        \\sliders. A direction of "backward" or "forward" must be provided. A
        \\slider ID can be optionally specified to give the isolated slider an
        \\ID other than the default temporary ID 255, and the next or previous
        \\can also be linked for isolation movement. Linked axis parameter
        \\values must be one of "prev", "next", "left", or "right".
        ,
        .execute = &mclIsolate,
    });
    errdefer _ = command.registry.orderedRemove("ISOLATE");
    try command.registry.put("RECOVER_SLIDER", .{
        .name = "RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "new slider ID" },
            .{ .name = "use sensor", .resolve = false, .optional = true },
        },
        .short_description = "Recover an unrecognized slider on a given axis.",
        .long_description =
        \\Recover an unrecognized slider on a given axis. The provided slider
        \\ID must be a positive integer from 1 to 254 inclusive, and must be
        \\unique to other recognized slider IDs. If a sensor is optionally
        \\specified for use (valid sensor values include: front, back, left,
        \\right), recovery will use the specified hall sensor.
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
    try command.registry.put("SPD_MOVE_SLIDER_AXIS", .{
        .name = "SPD_MOVE_SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move slider to target axis center.",
        .long_description =
        \\Move given slider to the center of target axis. The slider ID must be
        \\currently recognized within the motion system. This command moves the
        \\slider with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_AXIS");
    try command.registry.put("SPD_MOVE_SLIDER_LOCATION", .{
        .name = "SPD_MOVE_SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination location" },
        },
        .short_description = "Move slider to target location.",
        .long_description =
        \\Move given slider to target location. The slider ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. This command
        \\moves the slider with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_LOCATION");
    try command.registry.put("SPD_MOVE_SLIDER_DISTANCE", .{
        .name = "SPD_MOVE_SLIDER_DISTANCE",
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
        \\may be negative for backward movement. This command moves the slider
        \\with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_DISTANCE");
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
    try command.registry.put("PUSH_SLIDER_FORWARD", .{
        .name = "PUSH_SLIDER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Push slider forward by slider length.",
        .long_description =
        \\Push slider forward with speed feedback-controlled movement. This
        \\movement targets a distance of the slider length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the slider.
        ,
        .execute = &mclSliderPushForward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_FORWARD");
    try command.registry.put("PUSH_SLIDER_BACKWARD", .{
        .name = "PUSH_SLIDER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Push slider backward by slider length.",
        .long_description =
        \\Push slider backward with speed feedback-controlled movement. This
        \\movement targets a distance of the slider length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the slider.
        ,
        .execute = &mclSliderPushBackward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_BACKWARD");
    try command.registry.put("PULL_SLIDER_FORWARD", .{
        .name = "PULL_SLIDER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
        },
        .short_description = "Pull incoming slider forward at axis.",
        .long_description =
        \\Pull incoming slider forward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_SLIDER" command.
        \\The pulled slider's ID must also be provided.
        ,
        .execute = &mclSliderPullForward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_SLIDER_FORWARD");
    try command.registry.put("PULL_SLIDER_BACKWARD", .{
        .name = "PULL_SLIDER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
        },
        .short_description = "Pull incoming slider backward at axis.",
        .long_description =
        \\Pull incoming slider backward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_SLIDER" command.
        \\The pulled slider's ID must also be provided.
        ,
        .execute = &mclSliderPullBackward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_SLIDER_BACKWARD");
    try command.registry.put("WAIT_PULL_SLIDER", .{
        .name = "WAIT_PULL_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Wait for slider pull to complete.",
        .long_description =
        \\Pause the execution of any further commands until active slider pull
        \\at the provided axis is indicated as complete.
        ,
        .execute = &mclSliderWaitPull,
    });
    try command.registry.put("STOP_PULL_SLIDER", .{
        .name = "STOP_PULL_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Stop active slider pull at axis.",
        .long_description =
        \\Stop active slider pull at axis.
        ,
        .execute = &mclSliderStopPull,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_SLIDER");
}

pub fn deinit() void {
    arena.deinit();
    line_names = undefined;
}

fn mclVersion(_: [][]const u8) !void {
    std.log.info("MCL Version: {d}.{d}.{d}\n", .{
        mcl.version.major,
        mcl.version.minor,
        mcl.version.patch,
    });
}

fn mclConnect(_: [][]const u8) !void {
    try mcl.open();
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = true;
            try station.send();
        }
    }
}

fn mclDisconnect(_: [][]const u8) !void {
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = false;
            try station.send();
        }
    }
    try mcl.close();
}

fn mclStationX(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollX();

    std.log.info("{}", .{line.stations[station_index].x});
}

fn mclStationY(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollY();

    std.log.info("{}", .{line.stations[station_index].y});
}

fn mclStationWr(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollWr();

    std.log.info("{}", .{line.stations[station_index].wr});
}

fn mclStationWw(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollWw();

    std.log.info("{}", .{line.stations[station_index].ww});
}

fn mclAxisSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const station_index: mcl.Station.Index = @intCast(axis_index / 3);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    const station = line.stations[station_index];
    try station.pollWr();

    const slider_id = station.wr.slider.axis(local_axis_index).id;

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

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    station.ww.target_axis_number = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0x5);
    // Reset on error as well as on success.
    defer station.resetY(0x5) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (!station.x.servo_active.axis(local_axis_index)) break;
    }
}

fn mclClearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    station.ww.target_axis_number = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0xB);
    // Reset on error as well as on success.
    defer station.resetY(0xB) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.errors_cleared) break;
    }
}

fn mclClearSliderInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const station = line.stations[axis_index / 3];
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    station.ww.target_axis_number = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0xC);
    // Reset on error as well as on success.
    defer station.resetY(0xC) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.axis_slider_info_cleared) break;
    }
}

fn mclCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    const station = line.stations[0];
    try waitCommandReady(station);
    station.ww.command_code = .Calibration;
    station.ww.command_slider_number = 1;
    try sendCommand(station);
}

fn setLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    const station = line.stations[0];
    try waitCommandReady(station);
    station.ww.command_code = .SetLineZero;
    try sendCommand(station);
}

fn mclIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(u16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const dir: Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .forward;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .backward;
        } else {
            return error.InvalidDirection;
        }
    };

    const slider_id: u16 = if (params[3].len > 0)
        try std.fmt.parseInt(u16, params[3], 0)
    else
        0;
    const link_axis: ?Direction = link: {
        if (params[4].len > 0) {
            if (std.ascii.eqlIgnoreCase("next", params[4]) or
                std.ascii.eqlIgnoreCase("right", params[4]))
            {
                break :link .forward;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .backward;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link null;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const station = line.stations[axis_index / 3];
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    try waitCommandReady(station);
    if (link_axis) |a| {
        if (a == .backward) {
            try station.setY(0xD);
            station.y.prev_axis_isolate_link = true;
        } else {
            try station.setY(0xE);
            station.y.next_axis_isolate_link = true;
        }
    }
    defer {
        if (link_axis) |a| {
            if (a == .backward) {
                if (station.resetY(0xD)) {
                    station.y.prev_axis_isolate_link = false;
                } else |_| {}
            } else {
                if (station.resetY(0xE)) {
                    station.y.next_axis_isolate_link = false;
                } else |_| {}
            }
        }
    }
    station.ww.* = .{
        .command_code = if (dir == .forward)
            .IsolateForward
        else
            .IsolateBackward,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
    };
    try sendCommand(station);
}

fn mclSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_speed = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_speed < 1 or slider_speed > 100) return error.InvalidSpeed;

    const line_idx: usize = try matchLine(line_names, line_name);
    line_speeds[line_idx] = @intCast(slider_speed);
}

fn mclSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_acceleration = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_acceleration < 1 or slider_acceleration > 100)
        return error.InvalidAcceleration;

    const line_idx: usize = try matchLine(line_names, line_name);
    line_accelerations[line_idx] = @intCast(slider_acceleration);
}

fn mclGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    std.log.info("Line {s} speed: {d}%", .{ line_name, line_speeds[line_idx] });
}

fn mclGetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    std.log.info(
        "Line {s} acceleration: {d}%",
        .{ line_name, line_accelerations[line_idx] },
    );
}

fn mclSliderLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;
    const result_var: []const u8 = params[2];

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main, _ =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;

    const station = main.station;

    const location: f32 = station.wr.slider.axis(main.index.station).location;

    std.log.info(
        "Slider {d} location: {d}mm",
        .{ slider_id, location },
    );
    if (result_var.len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(result_var, try std.fmt.bufPrint(
            &float_buf,
            "{d}",
            .{location},
        ));
    }
}

fn mclSliderAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();

    var axis: mcl.Axis.Id.Line = 1;
    for (line.stations) |station| {
        for (0..3) |_local_axis| {
            const local_axis: mcl.Axis.Index.Station = @intCast(_local_axis);
            if (station.wr.slider.axis(local_axis).id == slider_id) {
                std.log.info(
                    "Slider {d} axis: {}",
                    .{ slider_id, axis },
                );
            }
            axis += 1;
            if (axis > line.axes.len) break;
        }
    }
}

fn mclHallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollX();

    var axis: mcl.Axis.Id.Line = 1;
    for (line.stations) |station| {
        for (0..3) |_local_axis| {
            const local_axis: mcl.Axis.Index.Station = @intCast(_local_axis);
            const alarms = station.x.hall_alarm.axis(local_axis);

            if (alarms.back) {
                std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis});
            }
            if (alarms.front) {
                std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis});
            }

            axis += 1;
            if (axis > line.axes.len) break;
        }
    }
}

fn mclAssertHall(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseInt(mcl.Axis.Id.Line, params[2], 0);
    const side: mcl.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[3]) or
        std.ascii.eqlIgnoreCase("left", params[3]))
        .backward
    else if (std.ascii.eqlIgnoreCase("front", params[3]) or
        std.ascii.eqlIgnoreCase("right", params[3]))
        .forward
    else
        return error.InvalidHallAlarmSide;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    var alarm_on: bool = true;
    if (params[4].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[4])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[4])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }

    const station_ind: mcl.Station.Index = @intCast((axis - 1) / 3);
    const local_axis: mcl.Axis.Index.Station = @intCast((axis - 1) % 3);

    const station = line.stations[station_ind];
    try station.pollX();

    switch (side) {
        .backward => {
            if (station.x.hall_alarm.axis(local_axis).back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .forward => {
            if (station.x.hall_alarm.axis(local_axis).front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
    }
}

fn mclSliderPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line)) and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisByPosition,
        .command_slider_number = slider_id,
        .target_axis_number = axis_id,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main: mcl.Axis, const _aux: ?mcl.Axis =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }

        const current_location =
            main.station.wr.slider.axis(main.index.station).location;
        if (((direction == .forward and location > current_location) or
            (direction == .backward and location < current_location)) and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationByPosition,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const move_direction: Direction = move_dir: {
        if (distance > 0.0) {
            break :move_dir .forward;
        } else if (distance < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main: mcl.Axis, const _aux: ?mcl.Axis =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceByPosition,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line)) and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisBySpeed,
        .command_slider_number = slider_id,
        .target_axis_number = axis_id,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }

        const current_location =
            main.station.wr.slider.axis(main.index.station).location;
        if (((direction == .forward and location > current_location) or
            (direction == .backward and location < current_location)) and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationBySpeed,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_speeds[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const move_direction: Direction = move_dir: {
        if (distance > 0.0) {
            break :move_dir .forward;
        } else if (distance < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction and
            aux.station.wr.slider.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceBySpeed,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        if (direction == .forward) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderForward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        if (direction == .backward) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderBackward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const slider_id = try std.fmt.parseInt(u16, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(station);
    station.ww.* = .{
        .command_code = .PullAxisSliderForward,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const slider_id = try std.fmt.parseInt(u16, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(station);
    station.ww.* = .{
        .command_code = .PullAxisSliderBackward,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(station);
}

fn mclSliderWaitPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(i16, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        try station.pollWr();
        const slider_state = station.wr.slider.axis(local_axis).state;
        if (slider_state == .PullForwardCompleted or
            slider_state == .PullBackwardCompleted) break;
        if (slider_state == .PullForwardFault or
            slider_state == .PullBackwardFault)
            return error.SliderPullError;
    }
}

fn mclSliderStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(i16, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try station.setY(0x10 + @as(u6, local_axis));
    defer station.resetY(0x10 + @as(u6, local_axis)) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (!station.x.pulling_slider.axis(local_axis)) break;
    }
}

fn mclWaitMoveSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    while (true) {
        try command.checkCommandInterrupt();
        try line.pollWr();
        const main, _ = if (line.search(slider_id)) |t| t
        // Do not error here as the poll receiving CC-Link information can
        // "move past" a backwards traveling slider during transmission, thus
        // rendering the slider briefly invisible in the whole loop.
        else continue;
        const station = main.station.*;
        const wr = station.wr;

        if (wr.slider.axis(main.index.station).state == .PosMoveCompleted or
            wr.slider.axis(main.index.station).state == .SpdMoveCompleted)
        {
            break;
        }

        if (main.id.line < line.axes.len) {
            const next_axis_index = @rem(main.index.station + 1, 3);
            const next_station = if (next_axis_index == 0)
                line.stations[station.index + 1]
            else
                station;
            const slider_number =
                next_station.wr.slider.axis(next_axis_index).id;
            const slider_state =
                next_station.wr.slider.axis(next_axis_index).state;
            if (slider_number == slider_id and
                (slider_state == .PosMoveCompleted or
                slider_state == .SpdMoveCompleted))
            {
                break;
            }
        }
    }
}

fn mclRecoverSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: u16 = try std.fmt.parseUnsigned(u16, params[1], 0);
    const new_slider_id: u16 = try std.fmt.parseUnsigned(u16, params[2], 0);
    if (new_slider_id == 0 or new_slider_id > 254)
        return error.InvalidSliderID;
    const sensor: []const u8 = params[3];

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis < 1 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const use_sensor: ?Direction = parse_use_sensor: {
        if (sensor.len == 0) break :parse_use_sensor null;
        if (std.ascii.eqlIgnoreCase("back", sensor) or
            std.ascii.eqlIgnoreCase("left", sensor))
        {
            break :parse_use_sensor .backward;
        } else if (std.ascii.eqlIgnoreCase("front", sensor) or
            std.ascii.eqlIgnoreCase("right", sensor))
        {
            break :parse_use_sensor .forward;
        } else return error.InvalidSensorSide;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    const station = line.stations[axis_index / 3];
    try waitCommandReady(station);
    if (use_sensor) |side| {
        if (side == .backward) {
            try station.setY(0x13);
            station.y.recovery_use_hall_sensor.back = true;
        } else {
            try station.setY(0x14);
            station.y.recovery_use_hall_sensor.front = true;
        }
    }
    defer {
        if (use_sensor) |side| {
            if (side == .backward) {
                if (station.resetY(0x13)) {
                    station.y.recovery_use_hall_sensor.back = false;
                } else |_| {}
            } else {
                if (station.resetY(0x14)) {
                    station.y.recovery_use_hall_sensor.front = false;
                } else |_| {}
            }
        }
    }
    station.ww.* = .{
        .command_code = .RecoverSliderAtAxis,
        .target_axis_number = local_axis_index + 1,
        .command_slider_number = new_slider_id,
    };
    try sendCommand(station);
}

fn mclTrafficStop(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const direction: Direction = dir: {
        if (std.ascii.eqlIgnoreCase("next", params[2]) or
            std.ascii.eqlIgnoreCase("right", params[2]))
        {
            break :dir .forward;
        } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
            std.ascii.eqlIgnoreCase("left", params[2]))
        {
            break :dir .backward;
        } else return error.InvalidDirection;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const station = line.stations[axis_index / 3];
    try station.poll();

    station.y.stop_driver_transmission.setTo(direction, true);
    try station.sendY();
    while (!station.x.transmission_stopped.to(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX();
    }
}

fn mclTrafficAllow(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const direction: Direction = dir: {
        if (std.ascii.eqlIgnoreCase("next", params[2]) or
            std.ascii.eqlIgnoreCase("right", params[2]))
        {
            break :dir .forward;
        } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
            std.ascii.eqlIgnoreCase("left", params[2]))
        {
            break :dir .backward;
        } else return error.InvalidDirection;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const station = line.stations[axis_index / 3];
    try station.poll();

    station.y.stop_driver_transmission.setTo(direction, false);
    try station.sendY();
    while (station.x.transmission_stopped.to(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX();
    }
}

fn mclWaitRecoverSlider(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: u16 = try std.fmt.parseUnsigned(u16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    var slider_id: u16 = undefined;
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollWr();

        const slider_number = station.wr.slider.axis(local_axis_index).id;
        if (slider_number != 0 and station.wr.slider.axis(
            local_axis_index,
        ).state == .PosMoveCompleted) {
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

fn matchLine(names: [][]const u8, name: []const u8) !usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    } else {
        return error.LineNameNotFound;
    }
}

fn waitCommandReady(station: Station) !void {
    std.log.debug("Waiting for command ready state...", .{});
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.ready_for_command) break;
    }
}

fn sendCommand(station: Station) !void {
    std.log.debug("Sending command...", .{});
    try station.sendWw();
    try station.setY(0x2);
    errdefer station.resetY(0x2) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.command_received) {
            break;
        }
    }
    try station.resetY(0x2);

    try station.pollWr();
    const command_response = station.wr.command_response;

    std.log.debug("Resetting command received flag...", .{});
    try station.setY(0x3);
    errdefer station.resetY(0x3) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (!station.x.command_received) {
            try station.resetY(0x3);
            break;
        }
    }

    return switch (command_response) {
        .NoError => {},
        .InvalidCommand => error.InvalidCommand,
        .SliderNotFound => error.SliderNotFound,
        .HomingFailed => error.HomingFailed,
        .InvalidParameter => error.InvalidParameter,
        .InvalidSystemState => error.InvalidSystemState,
        .SliderAlreadyExists => error.SliderAlreadyExists,
        .InvalidAxis => error.InvalidAxis,
    };
}
