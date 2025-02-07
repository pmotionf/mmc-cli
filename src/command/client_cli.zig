const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const mmc = @import("mmc");
const network = @import("network");

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u7 = undefined;
var line_accelerations: []u7 = undefined;
const Direction = mcl.Direction;
const Station = mcl.Station;

var server: ?network.Socket = null;

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
    // log_lines = try allocator.alloc(LogLine, c.lines.len);
    for (0..c.lines.len) |i| {
        // log_lines[i].stations = .{false} ** 256;
        // log_lines[i].status = false;
        line_names[i] = try allocator.alloc(u8, c.line_names[i].len);
        @memcpy(line_names[i], c.line_names[i]);
        line_speeds[i] = 40;
        line_accelerations[i] = 40;
    }

    try network.init();

    // try command.registry.put("MCL_VERSION", .{
    //     .name = "MCL_VERSION",
    //     .short_description = "Display the version of MCL.",
    //     .long_description =
    //     \\Print the currently linked version of the PMF Motion Control Library
    //     \\in Semantic Version format.
    //     ,
    //     .execute = &mclVersion,
    // });
    // errdefer _ = command.registry.orderedRemove("MCL_VERSION");
    try command.registry.put("CONNECT", .{
        .name = "CONNECT",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "IP address" },
            .{ .name = "port" },
        },
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application with the server by providing
        \\the server IP address and port.
        ,
        .execute = &mmcConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    // try command.registry.put("DISCONNECT", .{
    //     .name = "DISCONNECT",
    //     .short_description = "Disconnect MCL from motion system.",
    //     .long_description =
    //     \\End MCL's connection with the motion system. This command should be
    //     \\run after other MCL commands are completed.
    //     ,
    //     .execute = &mclDisconnect,
    // });
    // errdefer _ = command.registry.orderedRemove("DISCONNECT");
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
    // try command.registry.put("PRINT_X", .{
    //     .name = "PRINT_X",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Poll and print the X register of a station.",
    //     .long_description =
    //     \\Poll and print the X register of a station. The station X register to
    //     \\be printed is determined by the provided axis.
    //     ,
    //     .execute = &mclStationX,
    // });
    // errdefer _ = command.registry.orderedRemove("PRINT_X");
    // try command.registry.put("PRINT_Y", .{
    //     .name = "PRINT_Y",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Poll and print the Y register of a station.",
    //     .long_description =
    //     \\Poll and print the Y register of a station. The station Y register to
    //     \\be printed is determined by the provided axis.
    //     ,
    //     .execute = &mclStationY,
    // });
    // errdefer _ = command.registry.orderedRemove("PRINT_Y");
    // try command.registry.put("PRINT_WR", .{
    //     .name = "PRINT_WR",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Poll and print the Wr register of a station.",
    //     .long_description =
    //     \\Poll and print the Wr register of a station. The station Wr register
    //     \\to be printed is determined by the provided axis.
    //     ,
    //     .execute = &mclStationWr,
    // });
    // errdefer _ = command.registry.orderedRemove("PRINT_WR");
    // try command.registry.put("PRINT_WW", .{
    //     .name = "PRINT_WW",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Poll and print the Ww register of a station.",
    //     .long_description =
    //     \\Poll and print the Ww register of a station. The station Ww register
    //     \\to be printed is determined by the provided axis.
    //     ,
    //     .execute = &mclStationWw,
    // });
    // errdefer _ = command.registry.orderedRemove("PRINT_WW");
    // try command.registry.put("AXIS_SLIDER", .{
    //     .name = "AXIS_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "result variable", .optional = true, .resolve = false },
    //     },
    //     .short_description = "Display slider on given axis, if exists.",
    //     .long_description =
    //     \\If a slider is recognized on the provided axis, print its slider ID.
    //     \\If a result variable name was provided, also store the slider ID in
    //     \\the variable.
    //     ,
    //     .execute = &mclAxisSlider,
    // });
    // errdefer _ = command.registry.orderedRemove("AXIS_SLIDER");
    // try command.registry.put("SLIDER_LOCATION", .{
    //     .name = "SLIDER_LOCATION",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "slider" },
    //         .{ .name = "result variable", .resolve = false, .optional = true },
    //     },
    //     .short_description = "Display a slider's location.",
    //     .long_description =
    //     \\Print a given slider's location if it is currently recognized in the
    //     \\provided line. If a result variable name is provided, then store the
    //     \\slider's location in the variable.
    //     ,
    //     .execute = &mclSliderLocation,
    // });
    // errdefer _ = command.registry.orderedRemove("SLIDER_LOCATION");
    // try command.registry.put("SLIDER_AXIS", .{
    //     .name = "SLIDER_AXIS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Display a slider's axis/axes.",
    //     .long_description =
    //     \\Print a given slider's axis if it is currently recognized in the
    //     \\provided line. If the slider is currently recognized across two axes,
    //     \\then both axes will be printed.
    //     ,
    //     .execute = &mclSliderAxis,
    // });
    // errdefer _ = command.registry.orderedRemove("SLIDER_AXIS");
    // try command.registry.put("HALL_STATUS", .{
    //     .name = "HALL_STATUS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis", .optional = true },
    //     },
    //     .short_description = "Display currently active hall sensors.",
    //     .long_description =
    //     \\List all active hall sensors. If an axis is provided, only hall
    //     \\sensors in that axis will be listed. Otherwise, all active hall
    //     \\sensors in the line will be listed.
    //     ,
    //     .execute = &mclHallStatus,
    // });
    // errdefer _ = command.registry.orderedRemove("HALL_STATUS");
    // try command.registry.put("ASSERT_HALL", .{
    //     .name = "ASSERT_HALL",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "side" },
    //         .{ .name = "on/off", .optional = true },
    //     },
    //     .short_description = "Check that a hall alarm is the expected state.",
    //     .long_description =
    //     \\Throw an error if a hall alarm is not in the specified state. Must
    //     \\identify the hall alarm with line name, axis, and a side ("back" or
    //     \\"front"). Can optionally specify the expected hall alarm state as
    //     \\"off" or "on"; if not specified, will default to "on".
    //     ,
    //     .execute = &mclAssertHall,
    // });
    // errdefer _ = command.registry.orderedRemove("ASSERT_HALL");
    // try command.registry.put("CLEAR_ERRORS", .{
    //     .name = "CLEAR_ERRORS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Clear driver errors of specified axis.",
    //     .long_description =
    //     \\Clear driver errors of specified axis.
    //     ,
    //     .execute = &mclClearErrors,
    // });
    // errdefer _ = command.registry.orderedRemove("CLEAR_ERRORS");
    // try command.registry.put("RESET_MCL", .{
    //     .name = "RESET_MCL",
    //     .short_description = "Reset all MCL registers.",
    //     .long_description =
    //     \\Reset all write registers (Y and Ww registers).
    //     ,
    //     .execute = &mclReset,
    // });
    // errdefer _ = command.registry.orderedRemove("RESET_MCL");
    // try command.registry.put("CLEAR_SLIDER_INFO", .{
    //     .name = "CLEAR_SLIDER_INFO",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Clear slider information at specified axis.",
    //     .long_description =
    //     \\Clear slider information at specified axis.
    //     ,
    //     .execute = &mclClearSliderInfo,
    // });
    // errdefer _ = command.registry.orderedRemove("CLEAR_SLIDER_INFO");
    // try command.registry.put("RELEASE_AXIS_SERVO", .{
    //     .name = "RELEASE_AXIS_SERVO",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Release the servo of a given axis.",
    //     .long_description =
    //     \\Release the servo of a given axis, allowing for free slider movement.
    //     \\This command should be run before sliders move within or exit from
    //     \\the system due to external influence.
    //     ,
    //     .execute = &mclAxisReleaseServo,
    // });
    // errdefer _ = command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    // try command.registry.put("STOP_TRAFFIC", .{
    //     .name = "STOP_TRAFFIC",
    //     .parameters = &.{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "direction" },
    //     },
    //     .short_description = "Prevent traffic communication to controller.",
    //     .long_description =
    //     \\Forcibly stop all traffic transmission from the specified axis's
    //     \\controller to its neighboring controller. The neighboring controller
    //     \\is determined by the provided direction.
    //     ,
    //     .execute = &mclTrafficStop,
    // });
    // errdefer _ = command.registry.orderedRemove("STOP_TRAFFIC");
    // try command.registry.put("ALLOW_TRAFFIC", .{
    //     .name = "ALLOW_TRAFFIC",
    //     .parameters = &.{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "direction" },
    //     },
    //     .short_description = "Resume traffic communication to controller.",
    //     .long_description =
    //     \\Permit all traffic transmission from the specified axis's controller
    //     \\to its neighboring controller. The neighboring controller is
    //     \\determined by the provided direction.
    //     ,
    //     .execute = &mclTrafficAllow,
    // });
    // errdefer _ = command.registry.orderedRemove("ALLOW_TRAFFIC");
    // try command.registry.put("CALIBRATE", .{
    //     .name = "CALIBRATE",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //     },
    //     .short_description = "Calibrate a system line.",
    //     .long_description =
    //     \\Calibrate a system line. An uninitialized slider must be positioned
    //     \\at the start of the line such that the first axis has both hall
    //     \\alarms active.
    //     ,
    //     .execute = &mclCalibrate,
    // });
    // errdefer _ = command.registry.orderedRemove("CALIBRATE");
    // try command.registry.put("SET_LINE_ZERO", .{
    //     .name = "SET_LINE_ZERO",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //     },
    //     .short_description = "Set line zero position.",
    //     .long_description =
    //     \\Set a system line's zero position based on a current slider's
    //     \\position. Aforementioned slider must be located at first axis of
    //     \\system line.
    //     ,
    //     .execute = &setLineZero,
    // });
    // errdefer _ = command.registry.orderedRemove("SET_LINE_ZERO");
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
    // try command.registry.put("RECOVER_SLIDER", .{
    //     .name = "RECOVER_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "new slider ID" },
    //         .{ .name = "use sensor", .resolve = false, .optional = true },
    //     },
    //     .short_description = "Recover an unrecognized slider on a given axis.",
    //     .long_description =
    //     \\Recover an unrecognized slider on a given axis. The provided slider
    //     \\ID must be a positive integer from 1 to 254 inclusive, and must be
    //     \\unique to other recognized slider IDs. If a sensor is optionally
    //     \\specified for use (valid sensor values include: front, back, left,
    //     \\right), recovery will use the specified hall sensor.
    //     ,
    //     .execute = &mclRecoverSlider,
    // });
    // errdefer _ = command.registry.orderedRemove("RECOVER_SLIDER");
    // try command.registry.put("WAIT_RECOVER_SLIDER", .{
    //     .name = "WAIT_RECOVER_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "result variable", .resolve = false, .optional = true },
    //     },
    //     .short_description = "Wait until recovery of slider is complete.",
    //     .long_description =
    //     \\Wait until slider recovery is complete and a slider is recognized.
    //     \\If an optional result variable name is provided, then store the
    //     \\recognized slider ID in the variable.
    //     ,
    //     .execute = &mclWaitRecoverSlider,
    // });
    // errdefer _ = command.registry.orderedRemove("WAIT_RECOVER_SLIDER");
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
    // try command.registry.put("WAIT_MOVE_SLIDER", .{
    //     .name = "WAIT_MOVE_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Wait for slider movement to complete.",
    //     .long_description =
    //     \\Pause the execution of any further commands until movement for the
    //     \\given slider is indicated as complete.
    //     ,
    //     .execute = &mclWaitMoveSlider,
    // });
    // errdefer _ = command.registry.orderedRemove("WAIT_MOVE_SLIDER");
    // try command.registry.put("PUSH_SLIDER_FORWARD", .{
    //     .name = "PUSH_SLIDER_FORWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Push slider forward by slider length.",
    //     .long_description =
    //     \\Push slider forward with speed feedback-controlled movement. This
    //     \\movement targets a distance of the slider length, and thus if it is
    //     \\used to cross a line boundary, the receiving axis at the destination
    //     \\line must first be pulling the slider.
    //     ,
    //     .execute = &mclSliderPushForward,
    // });
    // errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_FORWARD");
    // try command.registry.put("PUSH_SLIDER_BACKWARD", .{
    //     .name = "PUSH_SLIDER_BACKWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Push slider backward by slider length.",
    //     .long_description =
    //     \\Push slider backward with speed feedback-controlled movement. This
    //     \\movement targets a distance of the slider length, and thus if it is
    //     \\used to cross a line boundary, the receiving axis at the destination
    //     \\line must first be pulling the slider.
    //     ,
    //     .execute = &mclSliderPushBackward,
    // });
    // errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_BACKWARD");
    // try command.registry.put("PULL_SLIDER_FORWARD", .{
    //     .name = "PULL_SLIDER_FORWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Pull incoming slider forward at axis.",
    //     .long_description =
    //     \\Pull incoming slider forward at axis. This command must be stopped
    //     \\manually after it is completed with the "STOP_PULL_SLIDER" command.
    //     \\The pulled slider's ID must also be provided.
    //     ,
    //     .execute = &mclSliderPullForward,
    // });
    // errdefer _ = command.registry.orderedRemove("PULL_SLIDER_FORWARD");
    // try command.registry.put("PULL_SLIDER_BACKWARD", .{
    //     .name = "PULL_SLIDER_BACKWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "slider" },
    //     },
    //     .short_description = "Pull incoming slider backward at axis.",
    //     .long_description =
    //     \\Pull incoming slider backward at axis. This command must be stopped
    //     \\manually after it is completed with the "STOP_PULL_SLIDER" command.
    //     \\The pulled slider's ID must also be provided.
    //     ,
    //     .execute = &mclSliderPullBackward,
    // });
    // errdefer _ = command.registry.orderedRemove("PULL_SLIDER_BACKWARD");
    // try command.registry.put("WAIT_PULL_SLIDER", .{
    //     .name = "WAIT_PULL_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Wait for slider pull to complete.",
    //     .long_description =
    //     \\Pause the execution of any further commands until active slider pull
    //     \\at the provided axis is indicated as complete.
    //     ,
    //     .execute = &mclSliderWaitPull,
    // });
    // try command.registry.put("STOP_PULL_SLIDER", .{
    //     .name = "STOP_PULL_SLIDER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Stop active slider pull at axis.",
    //     .long_description =
    //     \\Stop active slider pull at axis.
    //     ,
    //     .execute = &mclSliderStopPull,
    // });
    // errdefer _ = command.registry.orderedRemove("STOP_PULL_SLIDER");
    // try command.registry.put("ADD_LOG_REGISTERS", .{
    //     .name = "ADD_LOG_REGISTERS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axes" },
    //         .{ .name = "registers" },
    //     },
    //     .short_description = "Add logging configuration for LOG_REGISTERS command.",
    //     .long_description =
    //     \\Setup the logging configuration for the specified line. This will
    //     \\overwrite the existing configuration for the specified line if any.
    //     \\It will log registers based on the given "registers" parameter on the
    //     \\station depending on the provided axes. Both "registers" and "axes"
    //     \\shall be provided as comma-separated values:
    //     \\
    //     \\"ADD_LOG_REGISTERS line_name 1,4,7 x,y"
    //     \\
    //     \\Both "registers" and "axes" accept "all" as the parameter to log every
    //     \\register and axes. The line configured for logging registers can be
    //     \\evaluated by "STATUS_LOG_REGISTERS" command.
    //     ,
    //     .execute = &addLogRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("ADD_LOG_REGISTERS");
    // try command.registry.put("REMOVE_LOG_REGISTERS", .{
    //     .name = "REMOVE_LOG_REGISTERS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //     },
    //     .short_description = "Remove the logging configuration for the specified line.",
    //     .long_description =
    //     \\Remove logging configuration for logging registers on the specified
    //     \\line.
    //     ,
    //     .execute = &removeLogRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("REMOVE_LOG_REGISTERS");
    // try command.registry.put("RESET_LOG_REGISTERS", .{
    //     .name = "RESET_LOG_REGISTERS",
    //     .short_description = "Remove all logging configurations.",
    //     .long_description =
    //     \\Remove all logging configurations for logging registers for every
    //     \\line.
    //     ,
    //     .execute = &resetLogRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("RESET_LOG_REGISTERS");
    // try command.registry.put("STATUS_LOG_REGISTERS", .{
    //     .name = "STATUS_LOG_REGISTERS",
    //     .short_description = "Print the logging configurations entry.",
    //     .long_description =
    //     \\Print the logging configuration for each line (if any). The status is
    //     \\given by "line_name:station_id:registers" with stations and registers
    //     \\are a comma-separated string.
    //     ,
    //     .execute = &statusLogRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("STATUS_LOG_REGISTERS");
    // try command.registry.put("FILE_LOG_REGISTERS", .{
    //     .name = "FILE_LOG_REGISTERS",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "path", .optional = true },
    //     },
    //     .short_description = "Create a logging file for the configured line.",
    //     .long_description =
    //     \\Create a log file for logging registers. If no logging configuration
    //     \\is detected, it will return an error value. If a path is not provided,
    //     \\a default log file containing all register values triggered by
    //     \\LOG_REGISTERS will be created in the current working directory as
    //     \\follows:
    //     \\"mmc-register-YYYY.MM.DD-HH.MM.SS.csv".
    //     \\
    //     \\Note that this command will not log any register value, the register
    //     \\will be logged by LOG_REGISTERS command.
    //     ,
    //     .execute = &pathLogRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("FILE_LOG_REGISTERS");
    // try command.registry.put("LOG_REGISTERS", .{
    //     .name = "LOG_REGISTERS",
    //     .short_description = "Log the register values.",
    //     .long_description =
    //     \\This command will trigger the logging functionality on every line
    //     \\configured for logging the registers. It writes register values to
    //     \\the file specified by FILE_LOG_REGISTERS.
    //     ,
    //     .execute = &logRegisters,
    // });
    // errdefer _ = command.registry.orderedRemove("LOG_REGISTERS");
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

pub fn mmcConnect(params: [][]const u8) !void {
    const IP_address = params[0];
    const port = try std.fmt.parseInt(
        u16,
        params[1],
        0,
    );
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
    } else {
        std.log.err("Failed to connect to server", .{});
    }
}

fn mclSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_speed = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_speed < 1 or slider_speed > 100) return error.InvalidSpeed;

    const line_idx: usize = try matchLine(line_names, line_name);

    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .set_speed;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .speed = slider_speed,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_acceleration = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_acceleration < 1 or slider_acceleration > 100)
        return error.InvalidAcceleration;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .set_acceleration;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .acceleration = slider_acceleration,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .get_speed;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclGetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .get_acceleration;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
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
    const link_axis: mmc.config.Direction = link: {
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
        } else break :link .no_direction;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .isolate;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = axis_index,
        .direction = dir,
        .carrier_id = slider_id,
        .link_axis = link_axis,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
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
    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .move_carrier_axis;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .axis_idx = axis_index,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSliderPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .move_carrier_location;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .location = location,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSliderPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;
    const line_idx: usize = try matchLine(line_names, line_name);

    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .move_carrier_distance;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .distance = distance,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSliderSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .spd_move_carrier_axis;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .axis_idx = axis_index,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSliderSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .spd_move_carrier_location;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .location = location,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn mclSliderSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx: usize = try matchLine(line_names, line_name);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;
    const kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.? = .spd_move_carrier_distance;
    const param: mmc.config.Command.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = slider_id,
        .distance = distance,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn matchLine(names: [][]u8, name: []const u8) !usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    } else {
        return error.LineNameNotFound;
    }
}

fn sendMessage(
    comptime kind: @typeInfo(
        mmc.config.Command,
    ).@"union".tag_type.?,
    param: mmc.config.Command.ParamType(kind),
    to_server: network.Socket,
) !void {
    const msg: mmc.message.messageType(kind) =
        .{
        .kind = @intFromEnum(kind),
        ._unused_kind = 0,
        .param = param,
        ._rest_param = 0,
    };
    std.log.debug("kind: {}", .{kind});
    std.log.debug("param: {}", .{param});
    try to_server.writer().writeStruct(msg);
    std.log.debug(
        "kind_size: {}, rest_kind: {}, param size: {}, rest: {}",
        .{
            @bitSizeOf(@TypeOf(msg.kind)),
            @bitSizeOf(@TypeOf(msg._unused_kind)),
            @bitSizeOf(@TypeOf(msg.param)),
            @bitSizeOf(@TypeOf(msg._rest_param)),
        },
    );
    // try to_server.writer().writeAll(std.mem.asBytes(&msg));
    std.log.debug("Wrote message {s}: {any}", .{
        @tagName(kind),
        std.mem.asBytes(&msg),
    });
}
