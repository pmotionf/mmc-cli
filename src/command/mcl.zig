const std = @import("std");
const command = @import("../command.zig");
const Mcl = @import("mcl/Mcl.zig");
const mmc_api = @import("mmc_api");

const Direction = Mcl.Direction;
const Distance = Mcl.Distance;
const Station = Mcl.Station;

var mcl: Mcl = undefined;

pub const Config = Mcl.Config;

pub fn init(gpa: std.mem.Allocator, io: std.Io, c: Config) !void {
    try Mcl.Config.validate(.{ .lines = c.lines });
    mcl = try .init(gpa, io, .{ .lines = c.lines });
    errdefer mcl.deinit(gpa);

    try command.registry.put(gpa, "CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect Mcl with motion system.",
        .long_description =
        \\Initialize Mcl's connection with the motion system. This command
        \\should be run before any other Mcl command, and also after any power
        \\cycle of the motion system.
        ,
        .execute = &mclConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    try command.registry.put(gpa, "DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect Mcl from motion system.",
        .long_description =
        \\End Mcl's connection with the motion system. This command should be
        \\run after other Mcl commands are completed.
        ,
        .execute = &mclDisconnect,
    });
    errdefer _ = command.registry.orderedRemove("DISCONNECT");
    try command.registry.put(gpa, "SET_SPEED", .{
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
    try command.registry.put(gpa, "SET_ACCELERATION", .{
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
    try command.registry.put(gpa, "GET_SPEED", .{
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
    try command.registry.put(gpa, "GET_ACCELERATION", .{
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
    try command.registry.put(gpa, "PRINT_X", .{
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
    try command.registry.put(gpa, "PRINT_Y", .{
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
    try command.registry.put(gpa, "PRINT_WR", .{
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
    try command.registry.put(gpa, "PRINT_WW", .{
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
    try command.registry.put(gpa, "AXIS_SLIDER", .{
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
    try command.registry.put(gpa, "SLIDER_LOCATION", .{
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
    try command.registry.put(gpa, "SLIDER_AXIS", .{
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
    try command.registry.put(gpa, "HALL_STATUS", .{
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
    try command.registry.put(gpa, "ASSERT_HALL", .{
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
    try command.registry.put(gpa, "CLEAR_ERRORS", .{
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
    try command.registry.put(gpa, "CLEAR_SLIDER_INFO", .{
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
    try command.registry.put(gpa, "SERVO_OFF", .{
        .name = "SERVO_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Release motor control of the given axis' driver.",
        .long_description =
        \\Release motor control of the given axis' driver, allowing for free
        \\slider movement. This command should be run before sliders move
        \\within or exit from the system due to external influence.
        ,
        .execute = &mclServoOff,
    });
    errdefer _ = command.registry.orderedRemove("SERVO_OFF");
    try command.registry.put(gpa, "SERVO_ON", .{
        .name = "SERVO_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Enable motor control of the given axis' driver.",
        .long_description =
        \\Enable motor control of the given axis' driver, allowing driver to
        \\execute slider-moving commands.
        ,
        .execute = &mclServoOn,
    });
    errdefer _ = command.registry.orderedRemove("SERVO_OFF");
    try command.registry.put(gpa, "STOP_TRAFFIC", .{
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
    try command.registry.put(gpa, "ALLOW_TRAFFIC", .{
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
    try command.registry.put(gpa, "CALIBRATE", .{
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
    try command.registry.put(gpa, "HOME_SLIDER", .{
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
    try command.registry.put(gpa, "WAIT_HOME_SLIDER", .{
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
    try command.registry.put(gpa, "ISOLATE", .{
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
    try command.registry.put(gpa, "RECOVER_SLIDER", .{
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
    try command.registry.put(gpa, "WAIT_RECOVER_SLIDER", .{
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
    try command.registry.put(gpa, "MOVE_SLIDER_AXIS", .{
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
    try command.registry.put(gpa, "MOVE_SLIDER_LOCATION", .{
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
    try command.registry.put(gpa, "MOVE_SLIDER_DISTANCE", .{
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
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_AXIS", .{
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
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_LOCATION", .{
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
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_DISTANCE", .{
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
    try command.registry.put(gpa, "WAIT_MOVE_SLIDER", .{
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
    try command.registry.put(gpa, "PUSH_SLIDER_FORWARD", .{
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
    try command.registry.put(gpa, "PUSH_SLIDER_BACKWARD", .{
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
    try command.registry.put(gpa, "PULL_SLIDER_FORWARD", .{
        .name = "PULL_SLIDER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
            .{ .name = "location" },
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
    try command.registry.put(gpa, "PULL_SLIDER_BACKWARD", .{
        .name = "PULL_SLIDER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
            .{ .name = "location" },
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
    try command.registry.put(gpa, "WAIT_PULL_SLIDER", .{
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
    try command.registry.put(gpa, "STOP_PULL_SLIDER", .{
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
    try command.registry.put(gpa, "EMERGENCY_STOP_ON", .{
        .name = "EMERGENCY_STOP_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Stop all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Enable emergency stop on all drivers.
            \\Optional: Enable emergency stop only on specified line.
        , .{}),
        .execute = &mclStopOn,
    });
    errdefer _ = command.registry.orderedRemove("EMERGENCY_STOP_ON");
    try command.registry.put(gpa, "PAUSE_ON", .{
        .name = "PAUSE_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Pause all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Enable pause on all drivers.
            \\Optional: Enable pause only on specified Line.
        , .{}),
        .execute = &mclPauseOn,
    });
    errdefer _ = command.registry.orderedRemove("PAUSE_ON");
    try command.registry.put(gpa, "EMERGENCY_STOP_OFF", .{
        .name = "EMERGENCY_STOP_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Stop all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Disable emergency stop on all drivers.
            \\Optional: Disable emergency stop only on specified Line.
        , .{}),
        .execute = &mclStopOff,
    });
    errdefer _ = command.registry.orderedRemove("EMERGENCY_STOP_OFF");
    try command.registry.put(gpa, "PAUSE_OFF", .{
        .name = "PAUSE_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Pause all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Disable pause on all drivers.
            \\Optional: Disable pause only on specified Line.
        , .{}),
        .execute = &mclPauseOff,
    });
    errdefer _ = command.registry.orderedRemove("PAUSE_OFF");
    try command.registry.put(gpa, "ENABLE_LOCKUP", .{
        .name = "ENABLE_LOCKUP",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Enable lockup at axis",
        .long_description = std.fmt.comptimePrint(
            \\Enable lockup at targeted axis. Lockup functionality prevents
            \\vibration to the carrier when the carrier stays still while being
            \\controlled.
        , .{}),
        .execute = &mclEnableLockup,
    });
    errdefer _ = command.registry.orderedRemove("ENABLE_LOCKUP");
    try command.registry.put(gpa, "DISABLE_LOCKUP", .{
        .name = "DISABLE_LOCKUP",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Disable lockup at axis",
        .long_description = std.fmt.comptimePrint(
            \\Disable lockup at targeted axis.
        , .{}),
        .execute = &mclDisableLockup,
    });
    errdefer _ = command.registry.orderedRemove("DISABLE_LOCKUP");
}

pub fn deinit(gpa: std.mem.Allocator) void {
    mcl.deinit(gpa);
}

fn mclConnect(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    try mcl.open(io);
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = true;
            try station.send(io);
        }
    }
}

fn mclDisconnect(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = false;
            try station.send(io);
        }
    }
    try mcl.close(io);
}

fn mclStationX(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollX(io);

    std.log.info("{f}", .{station.x});
}

fn mclStationY(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollY(io);

    std.log.info("{f}", .{station.y});
}

fn mclStationWr(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollWr(io);

    std.log.info("{f}", .{station.wr});
}

fn mclStationWw(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollWw(io);

    std.log.info("{f}", .{station.ww});
}

fn mclAxisSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const result_var: []const u8 = params[2];

    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollWr(io);

    const slider_id = station.wr.slider_number.axis(axis.index.station);

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

fn mclServoOff(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const station = line.axes[axis_id - 1].station.*;

    try station.setY(io, 0x6);
    check_servo: while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        for (station.axes) |axis| {
            if (station.x.servo_active.axis(axis.index.station)) {
                continue :check_servo;
            }
        }
        return;
    }
}

fn mclServoOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(usize, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const station = line.axes[axis_id - 1].station.*;

    try station.resetY(io, 0x6);
}

fn mclClearErrors(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    station.ww.target_axis_number = axis.id.station;
    try station.sendWw(io);
    try station.setY(io, 0xB);
    // Reset on error as well as on success.
    defer station.resetY(io, 0xB) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (station.x.errors_cleared) break;
    }
}

fn mclClearSliderInfo(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    station.ww.target_axis_number = axis.id.station;
    try station.sendWw(io);
    try station.setY(io, 0xC);
    // Reset on error as well as on success.
    defer station.resetY(io, 0xC) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (station.x.axis_slider_info_cleared) break;
    }
}

fn mclCalibrate(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line = try mcl.getLine(line_name);

    const station = line.stations[0];
    try checkCommandReady(io, station);
    station.ww.command_code = .Calibration;
    station.ww.command_slider_number = 1;
    try sendCommand(io, station);
}

fn mclHomeSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line = try mcl.getLine(line_name);

    const station = line.stations[0];

    try checkCommandReady(io, station);
    station.ww.command_code = .Home;
    try sendCommand(io, station);
}

fn mclWaitHomeSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const result_var: []const u8 = params[1];

    const line = try mcl.getLine(line_name);

    const station = line.stations[0];

    var slider: ?u16 = null;
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollWr(io);

        if (station.wr.slider_number.axis1 != 0) {
            slider = station.wr.slider_number.axis1;
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

fn mclIsolate(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
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
        std.fmt.parseInt(u16, params[3], 0) catch return error.InvalidSliderId
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

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    // Checks if the target axis actually have a slider on top of it
    try station.pollX(io);
    const hall_target_axis = station.x.hall_alarm.axis(axis.index.station);
    if (!hall_target_axis.back and !hall_target_axis.front) {
        // Returning invalid parameter to match the firmware response code
        return error.InvalidParameter;
    }

    try line.pollWr(io);
    // Checks if the slider already exists on the line
    if (line.search(slider_id) != null) {
        return error.SliderAlreadyExists;
    }

    try checkCommandReady(io, station);
    if (link_axis) |a| {
        if (a == .backward) {
            try station.setY(io, 0xD);
            station.y.prev_axis_isolate_link = true;
        } else {
            try station.setY(io, 0xE);
            station.y.next_axis_isolate_link = true;
        }
    }
    defer {
        if (link_axis) |a| {
            if (a == .backward) {
                if (station.resetY(io, 0xD)) {
                    station.y.prev_axis_isolate_link = false;
                } else |_| {}
            } else {
                if (station.resetY(io, 0xE)) {
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
        .target_axis_number = axis.id.station,
    };
    try sendCommand(io, station);
}

fn mclSetSpeed(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_speed = std.fmt.parseUnsigned(u7, params[1], 0) catch {
        return error.InvalidSpeed;
    };
    if (slider_speed < 1 or slider_speed > 100) {
        return error.InvalidSpeed;
    }

    const line = try mcl.getLine(line_name);
    line.speed = @intCast(slider_speed);
}

fn mclSetAcceleration(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_acceleration = std.fmt.parseUnsigned(u7, params[1], 0) catch {
        return error.InvalidAcceleration;
    };
    if (slider_acceleration < 1 or slider_acceleration > 100)
        return error.InvalidAcceleration;

    const line = try mcl.getLine(line_name);
    line.acceleration = @intCast(slider_acceleration);
}

fn mclGetSpeed(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line = try mcl.getLine(line_name);
    std.log.info("Line {s} speed: {d}%", .{ line_name, line.speed });
}

fn mclGetAcceleration(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line = try mcl.getLine(line_name);
    std.log.info(
        "Line {s} acceleration: {d}%",
        .{ line_name, line.acceleration },
    );
}

fn mclSliderLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }
    const result_var: []const u8 = params[2];

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);
    const main, _ =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;

    const station = main.station;

    const location: Distance =
        station.wr.slider_location.axis(main.index.station);

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

fn mclSliderAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);

    var axis: Mcl.Axis.Id.Line = 1;
    for (line.stations) |station| {
        for (0..3) |_local_axis| {
            const local_axis: Mcl.Axis.Index.Station = @intCast(_local_axis);
            if (station.wr.slider_number.axis(local_axis) == slider_id) {
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

fn mclHallStatus(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: ?Mcl.Axis.Id.Line = if (params[1].len > 0)
        std.fmt.parseInt(
            Mcl.Axis.Id.Line,
            params[1],
            0,
        ) catch return error.InvalidAxis
    else
        null;
    const line = try mcl.getLine(line_name);
    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) {
            return error.InvalidAxis;
        }
    }

    try line.pollX(io);
    if (axis_id) |id| {
        const axis = line.axes[id - 1];
        const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
        if (alarms.back) {
            std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
        }
        if (alarms.front) {
            std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
        }
    } else for (line.stations) |station| {
        for (station.axes) |axis| {
            const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
            if (alarms.back) {
                std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
            }
            if (alarms.front) {
                std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
            }
        }
    }
}

fn mclAssertHall(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const side: Mcl.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .backward
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .forward
        else
            return error.InvalidHallAlarmSide;
    const line = try mcl.getLine(line_name);
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

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.pollX(io);

    switch (side) {
        .backward => {
            if (station.x.hall_alarm.axis(axis.index.station).back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .forward => {
            if (station.x.hall_alarm.axis(axis.index.station).front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
    }
}

fn mclSliderPosMoveAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[2], 0) catch {
        return error.InvalidAxis;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis = line.axes[axis_id - 1];
    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line))
        {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisByPosition,
        .command_slider_number = slider_id,
        .target_axis_number = axis.id.line,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPosMoveLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line = try mcl.getLine(line_name);
    // Check if the target location is in valid range
    const max_location_target = line.slider_length / 2 +
        line.axes[0].length *
            @as(f32, @floatFromInt((line.axes.len - 1)));
    if (location_float < -line.slider_length / 2 or location_float > max_location_target) {
        return error.InvalidParameter;
    }

    try line.pollWr(io);
    const main: Mcl.Axis, const _aux: ?Mcl.Axis =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;
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
            main.station.wr.slider_location.axis(main.index.station).toFloat();
        if ((direction == .forward and location_float > current_location) or
            (direction == .backward and location_float < current_location))
        {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationByPosition,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPosMoveDistance(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const move_direction: Direction = move_dir: {
        if (distance_float > 0.0) {
            break :move_dir .forward;
        } else if (distance_float < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const distance: Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);
    const main: Mcl.Axis, const _aux: ?Mcl.Axis =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;

    // Check if the final target location is in valid range
    const current_location =
        station.wr.slider_location.axis(main.index.station).toFloat();
    const target_location = current_location + distance_float;
    const max_location_target = line.slider_length / 2 +
        line.axes[0].length *
            @as(f32, @floatFromInt((line.axes.len - 1)));
    if (target_location < -line.slider_length / 2 or
        target_location > max_location_target)
    {
        return error.InvalidParameter;
    }
    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction) {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceByPosition,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderSpdMoveAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[2], 0) catch {
        return error.InvalidAxis;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis = line.axes[axis_id - 1];
    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line))
        {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisBySpeed,
        .command_slider_number = slider_id,
        .target_axis_number = axis.id.line,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderSpdMoveLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line = try mcl.getLine(line_name);
    // Check if the target location is in valid range
    const max_location_target = line.slider_length / 2 +
        line.axes[0].length *
            @as(f32, @floatFromInt((line.axes.len - 1)));
    if (location_float < -line.slider_length / 2 or location_float > max_location_target) {
        return error.InvalidParameter;
    }

    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;
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
            main.station.wr.slider_location.axis(main.index.station).toFloat();
        if ((direction == .forward and location_float > current_location) or
            (direction == .backward and location_float < current_location))
        {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationBySpeed,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.speed,
    };
    try sendCommand(io, station);
}

fn mclSliderSpdMoveDistance(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const move_direction: Direction = move_dir: {
        if (distance_float > 0.0) {
            break :move_dir .forward;
        } else if (distance_float < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const distance: Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;

    // Check if the final target location is in valid range
    const current_location =
        station.wr.slider_location.axis(main.index.station).toFloat();
    const target_location = current_location + distance_float;
    const max_location_target = line.slider_length / 2 +
        line.axes[0].length *
            @as(f32, @floatFromInt((line.axes.len - 1)));
    if (target_location < -line.slider_length / 2 or
        target_location > max_location_target)
    {
        return error.InvalidParameter;
    }
    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction) {
            station = aux.station.*;
        }
    }

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceBySpeed,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPushForward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;
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

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderForward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPushBackward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);

    try line.pollWr(io);
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: Mcl.Station = main.station.*;

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

    try checkCommandReady(io, station);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.set(direction);
        try main.station.sendY(io);
        defer {
            main.station.y.stop_driver_transmission.reset(direction);
            main.station.sendY(io) catch {};
        }
        while (!main.station.x.transmission_stopped.from(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX(io);
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderBackward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPullForward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const slider_id = std.fmt.parseInt(u16, params[2], 0) catch return error.InvalidSliderId;
    const location_float = try std.fmt.parseFloat(f32, params[3]);
    const line = try mcl.getLine(line_name);
    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    try line.pollWr(io);
    // Checks if the slider already exists on the line
    if (line.search(slider_id) != null) {
        return error.SliderAlreadyExists;
    }

    try checkCommandReady(io, station);
    station.ww.* = .{
        .command_code = .PullAxisSliderForward,
        .location_distance = location,
        .command_slider_number = slider_id,
        .target_axis_number = axis.id.station,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderPullBackward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const slider_id = std.fmt.parseInt(u16, params[2], 0) catch return error.InvalidSliderId;
    const location_float = try std.fmt.parseFloat(f32, params[3]);
    const line = try mcl.getLine(line_name);
    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    try line.pollWr(io);
    // Checks if the slider already exists on the line
    if (line.search(slider_id) != null) {
        return error.SliderAlreadyExists;
    }

    try checkCommandReady(io, station);
    station.ww.* = .{
        .command_code = .PullAxisSliderBackward,
        .location_distance = location,
        .command_slider_number = slider_id,
        .target_axis_number = axis.id.station,
        .speed_percentage = line.speed,
        .acceleration_percentage = line.acceleration,
    };
    try sendCommand(io, station);
}

fn mclSliderWaitPull(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len)
        return error.InvalidAxis;

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        try station.pollWr(io);
        const slider_state = station.wr.slider_state.axis(axis.index.station);
        if (slider_state == .PullForwardCompleted or
            slider_state == .PullBackwardCompleted) break;
        if (slider_state == .PullForwardFault or
            slider_state == .PullBackwardFault)
            return error.SliderPullError;
    }
}

fn mclSliderStopPull(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const line = try mcl.getLine(line_name);

    if (axis_id < 1 or axis_id > line.axes.len)
        return error.InvalidAxis;

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    try station.setY(io, 0x10 + @as(u6, axis.index.station));
    defer station.resetY(io, 0x10 + @as(u6, axis.index.station)) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (!station.x.pulling_slider.axis(axis.index.station)) break;
    }
}

fn mclWaitMoveSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = std.fmt.parseInt(u16, params[1], 0) catch {
        return error.InvalidSliderId;
    };
    if (slider_id == 0 or slider_id > 254) {
        return error.InvalidSliderId;
    }

    const line = try mcl.getLine(line_name);

    while (true) {
        try command.checkCommandInterrupt();
        try line.pollWr(io);
        const main, _ = if (line.search(slider_id)) |t| t
            // Do not error here as the poll receiving CC-Link information can
            // "move past" a backwards traveling slider during transmission, thus
            // rendering the slider briefly invisible in the whole loop.
            else continue;
        const station = main.station.*;
        const wr = station.wr;

        if (wr.slider_state.axis(main.index.station) == .PosMoveCompleted or
            wr.slider_state.axis(main.index.station) == .SpdMoveCompleted)
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
                next_station.wr.slider_number.axis(next_axis_index);
            const slider_state =
                next_station.wr.slider_state.axis(next_axis_index);
            if (slider_number == slider_id and
                (slider_state == .PosMoveCompleted or
                    slider_state == .SpdMoveCompleted))
            {
                break;
            }
        }
    }
}

fn mclRecoverSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const new_slider_id: u16 = try std.fmt.parseUnsigned(u16, params[2], 0);
    if (new_slider_id == 0 or new_slider_id > 254)
        return error.InvalidSliderID;
    const sensor: []const u8 = params[3];

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len)
        return error.InvalidAxis;

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

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    // Checks if the target axis actually have a slider on top of it
    try station.pollX(io);
    const hall_target_axis = station.x.hall_alarm.axis(axis.index.station);
    if (!hall_target_axis.back and !hall_target_axis.front) {
        // Returning invalid parameter to match the firmware response code
        return error.InvalidParameter;
    }

    try line.pollWr(io);
    // Checks if the slider already exists on the line
    if (line.search(new_slider_id) != null) {
        return error.SliderAlreadyExists;
    }
    try checkCommandReady(io, station);
    if (use_sensor) |side| {
        if (side == .backward) {
            try station.setY(io, 0x13);
            station.y.recovery_use_hall_sensor.back = true;
        } else {
            try station.setY(io, 0x14);
            station.y.recovery_use_hall_sensor.front = true;
        }
    }
    defer {
        if (use_sensor) |side| {
            if (side == .backward) {
                if (station.resetY(io, 0x13)) {
                    station.y.recovery_use_hall_sensor.back = false;
                } else |_| {}
            } else {
                if (station.resetY(io, 0x14)) {
                    station.y.recovery_use_hall_sensor.front = false;
                } else |_| {}
            }
        }
    }
    station.ww.* = .{
        .command_code = .RecoverSliderAtAxis,
        .target_axis_number = axis.id.station,
        .command_slider_number = new_slider_id,
    };
    try sendCommand(io, station);
}

fn mclTrafficStop(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id == 0 or axis_id > line.axes.len) {
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

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.poll(io);

    station.y.stop_driver_transmission.set(direction);
    try station.sendY(io);
    while (!station.x.transmission_stopped.from(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
    }
}

fn mclTrafficAllow(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id == 0 or axis_id > line.axes.len) {
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

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;
    try station.poll(io);

    station.y.stop_driver_transmission.reset(direction);
    try station.sendY(io);
    while (station.x.transmission_stopped.from(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
    }
}

fn mclWaitRecoverSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(Mcl.Axis.Id.Line, params[1], 0) catch {
        return error.InvalidAxis;
    };
    const result_var: []const u8 = params[2];

    const line = try mcl.getLine(line_name);
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station.*;

    var slider_id: u16 = undefined;
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollWr(io);

        const slider_number = station.wr.slider_number.axis(axis.index.station);
        if (slider_number != 0 and station.wr.slider_state.axis(
            axis.index.station,
        ) == .PosMoveCompleted) {
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

fn mclStopOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line = try mcl.getLine(line_name);
        // Enable emergency stop for all drivers on the line
        for (line.stations) |station| {
            try station.setY(io, 0x7);
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX(io);
                if (!station.x.emergency_stop_enabled) continue :wait_stop;
            }
            return;
        }
    } else {
        // Enable emergency stop for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.setY(io, 0x7);
            }
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX(io);
                    if (!station.x.emergency_stop_enabled) continue :wait_stop;
                }
            }
            return;
        }
    }
}

fn mclStopOff(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line = try mcl.getLine(line_name);
        // Enable emergency stop for all drivers on the line
        for (line.stations) |station| {
            try station.resetY(io, 0x7);
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX(io);
                if (station.x.emergency_stop_enabled) continue :wait_stop;
            }
            return;
        }
    } else {
        // Enable emergency stop for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.resetY(io, 0x7);
            }
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX(io);
                    if (station.x.emergency_stop_enabled) continue :wait_stop;
                }
            }
            return;
        }
    }
}

fn mclPauseOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line = try mcl.getLine(line_name);
        // Enable temporary pause for all drivers on the line
        for (line.stations) |station| {
            try station.setY(io, 0x8);
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX(io);
                if (!station.x.paused) continue :wait_pause;
            }
            return;
        }
    } else {
        // Enable temporary pause for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.setY(io, 0x8);
            }
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX(io);
                    if (!station.x.paused) continue :wait_pause;
                }
            }
            return;
        }
    }
}

fn mclPauseOff(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line = try mcl.getLine(line_name);
        // Enable temporary pause for all drivers on the line
        for (line.stations) |station| {
            try station.resetY(io, 0x8);
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX(io);
                if (station.x.paused) continue :wait_pause;
            }
            return;
        }
    } else {
        // Enable temporary pause for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.resetY(io, 0x8);
            }
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX(io);
                    if (station.x.paused) continue :wait_pause;
                }
            }
            return;
        }
    }
}

fn mclEnableLockup(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(usize, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    station.y.lockup.setAxis(axis.index.station);
    try station.sendY(io);
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (station.x.lockup.axis(axis.index.station)) {
            return;
        }
    }
}

fn mclDisableLockup(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = std.fmt.parseInt(usize, params[1], 0) catch {
        return error.InvalidAxis;
    };

    const line = try mcl.getLine(line_name);
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    station.y.lockup.resetAxis(axis.index.station);
    try station.sendY(io);
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (station.x.lockup.axis(axis.index.station) == false) {
            return;
        }
    }
}

fn checkCommandReady(io: std.Io, station: Station) !void {
    try station.pollX(io);
    if (station.x.ready_for_command)
        return
    else
        return error.StationNotReady;
}

fn sendCommand(io: std.Io, station: Station) !void {
    std.log.debug("Sending command on station {}", .{station.id});
    try station.sendWw(io);
    try station.setY(io, 0x2);
    errdefer station.resetY(io, 0x2) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (station.x.command_received) {
            break;
        }
    }
    try station.resetY(io, 0x2);

    try station.pollWr(io);
    const command_response = station.wr.command_response;

    std.log.debug("Resetting command received flag...", .{});
    try station.setY(io, 0x3);
    errdefer station.resetY(io, 0x3) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX(io);
        if (!station.x.command_received) {
            try station.resetY(io, 0x3);
            break;
        }
    }
    std.log.debug("command code: {t}", .{command_response});
    try command_response.throwError();
}

test {
    std.testing.refAllDecls(@This());
}
