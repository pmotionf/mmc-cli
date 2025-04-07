const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const chrono = @import("chrono");

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u5 = undefined;
var line_accelerations: []u8 = undefined;
var log_file: ?std.fs.File = null;
var log_time_start: i64 = 0;

const Direction = mcl.Direction;
const Station = mcl.Station;

const LogLine = struct {
    /// Flag if line is configured for logging or not
    status: bool,
    /// Specify which registers to log for each line
    registers: std.EnumArray(RegisterType, bool),
    /// Flag which stations to be logged based on axes provided by user
    stations: [256]bool,

    const RegisterType = enum { x, y, wr, ww };
};

const Registers = struct {
    x: mcl.registers.X,
    y: mcl.registers.Y,
    wr: mcl.registers.Wr,
    ww: mcl.registers.Ww,
};

var log_lines: []LogLine = undefined;

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
    line_speeds = try allocator.alloc(u5, c.lines.len);
    line_accelerations = try allocator.alloc(u8, c.lines.len);
    log_lines = try allocator.alloc(LogLine, c.lines.len);
    for (0..c.lines.len) |i| {
        log_lines[i].stations = .{false} ** 256;
        log_lines[i].status = false;
        line_names[i] = try allocator.alloc(u8, c.line_names[i].len);
        @memcpy(line_names[i], c.line_names[i]);
        line_speeds[i] = 12;
        line_accelerations[i] = 78;
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
            .{ .name = "speed" },
        },
        .short_description = "Set the speed of carrier movement for a line.",
        .long_description =
        \\Set the speed of carrier movement for a line. The line is referenced
        \\by its name. The speed must be greater than 0 and less than or equal
        \\to 3.0 meters-per-second.
        ,
        .execute = &mclSetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("SET_SPEED");
    try command.registry.put("SET_ACCELERATION", .{
        .name = "SET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "acceleration" },
        },
        .short_description = "Set the acceleration of carrier movement.",
        .long_description =
        \\Set the acceleration of carrier movement for a line. The line is
        \\referenced by its name. The acceleration must be greater than 0 and
        \\less than or equal to 19.6 meters-per-second-squared.
        ,
        .execute = &mclSetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("SET_ACCELERATION");
    try command.registry.put("GET_SPEED", .{
        .name = "GET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the speed of carrier movement for a line.",
        .long_description =
        \\Get the speed of carrier movement for a line. The line is referenced
        \\by its name. Speed is in meters-per-second.
        ,
        .execute = &mclGetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("GET_SPEED");
    try command.registry.put("GET_ACCELERATION", .{
        .name = "GET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the acceleration of carrier movement.",
        .long_description =
        \\Get the acceleration of carrier movement for a line. The line is
        \\referenced by its name. Acceleration is in meters-per-second-squared.
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
    try command.registry.put("AXIS_CARRIER", .{
        .name = "AXIS_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "result variable", .optional = true, .resolve = false },
        },
        .short_description = "Display carrier on given axis, if exists.",
        .long_description =
        \\If a carrier is recognized on the provided axis, print its ID.
        \\If a result variable name was provided, also store the carrier ID in
        \\the variable.
        ,
        .execute = &mclAxisCarrier,
    });
    errdefer _ = command.registry.orderedRemove("AXIS_CARRIER");
    try command.registry.put("CARRIER_LOCATION", .{
        .name = "CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Display a carrier's location.",
        .long_description =
        \\Print a given carrier's location if it is currently recognized in
        \\the provided line. If a result variable name is provided, then store
        \\the carrier's location in the variable.
        ,
        .execute = &mclCarrierLocation,
    });
    errdefer _ = command.registry.orderedRemove("CARRIER_LOCATION");
    try command.registry.put("CARRIER_AXIS", .{
        .name = "CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Display a carrier's axis/axes.",
        .long_description =
        \\Print a given carrier's axis if it is currently recognized in the
        \\provided line. If the carrier is currently recognized across two
        \\axes, then both axes will be printed.
        ,
        .execute = &mclCarrierAxis,
    });
    errdefer _ = command.registry.orderedRemove("CARRIER_AXIS");
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
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Clear driver errors.",
        .long_description =
        \\Clear driver errors of specified axis. If no axis is provided, clear
        \\driver errors of all axis.
        ,
        .execute = &mclClearErrors,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put("RESET_MCL", .{
        .name = "RESET_MCL",
        .short_description = "Reset all MCL registers.",
        .long_description =
        \\Reset all write registers (Y and Ww registers).
        ,
        .execute = &mclReset,
    });
    errdefer _ = command.registry.orderedRemove("RESET_MCL");
    try command.registry.put("CLEAR_CARRIER_INFO", .{
        .name = "CLEAR_CARRIER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Clear carrier information.",
        .long_description =
        \\Clear carrier information at specified axis. If no axis is provided,
        \\clear carrier information at all axis
        ,
        .execute = &mclClearCarrierInfo,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    try command.registry.put("RELEASE_AXIS_SERVO", .{
        .name = "RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Release the servo of a given axis.",
        .long_description =
        \\Release the servo of a given axis, allowing for free carrier
        \\movement. This command should be run before carriers move within or
        \\exit from the system due to external influence.
        ,
        .execute = &mclAxisReleaseServo,
    });
    errdefer _ = command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put("CALIBRATE", .{
        .name = "CALIBRATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Calibrate a system line.",
        .long_description =
        \\Calibrate a system line. An uninitialized carrier must be positioned
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
        \\Set a system line's zero position based on a current carrier's
        \\position. Aforementioned carrier must be located at first axis of
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
            .{ .name = "carrier id", .optional = true },
            .{ .name = "link axis", .resolve = false, .optional = true },
        },
        .short_description = "Isolate an uninitialized carrier backwards.",
        .long_description =
        \\Slowly move an uninitialized carrier to separate it from other
        \\nearby carriers. A direction of "backward" or "forward" must be
        \\provided. A carrier ID can be optionally specified to give the
        \\isolated carrier an ID other than the default temporary ID 255, and
        \\the next or previous can also be linked for isolation movement.
        \\Linked axis parameter values must be one of "prev" or "next".
        ,
        .execute = &mclIsolate,
    });
    errdefer _ = command.registry.orderedRemove("ISOLATE");
    try command.registry.put("MOVE_CARRIER_AXIS", .{
        .name = "MOVE_CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must
        \\be currently recognized within the motion system.
        ,
        .execute = &mclCarrierPosMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_CARRIER_AXIS");
    try command.registry.put("MOVE_CARRIER_LOCATION", .{
        .name = "MOVE_CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination location" },
        },
        .short_description = "Move carrier to target location.",
        .long_description =
        \\Move given carrier to target location. The carrier ID must be
        \\currently recognized within the motion system, and the target
        \\location must be provided in millimeters as a whole/decimal number.
        ,
        .execute = &mclCarrierPosMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_CARRIER_LOCATION");
    try command.registry.put("MOVE_CARRIER_DISTANCE", .{
        .name = "MOVE_CARRIER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "distance" },
        },
        .short_description = "Move carrier by a distance.",
        .long_description =
        \\Move given carrier by a provided distance. The carrier ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement.
        ,
        .execute = &mclCarrierPosMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_CARRIER_DISTANCE");
    try command.registry.put("SPD_MOVE_CARRIER_AXIS", .{
        .name = "SPD_MOVE_CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must
        \\be currently recognized within the motion system. This command moves
        \\the carrier with speed profile feedback.
        ,
        .execute = &mclCarrierSpdMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_CARRIER_AXIS");
    try command.registry.put("SPD_MOVE_CARRIER_LOCATION", .{
        .name = "SPD_MOVE_CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination location" },
        },
        .short_description = "Move carrier to target location.",
        .long_description =
        \\Move given carrier to target location. The carrier ID must be
        \\currently recognized within the motion system, and the target
        \\location must be provided in millimeters as a whole/decimal number.
        \\This command moves the carrier with speed profile feedback.
        ,
        .execute = &mclCarrierSpdMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_CARRIER_LOCATION");
    try command.registry.put("SPD_MOVE_CARRIER_DISTANCE", .{
        .name = "SPD_MOVE_CARRIER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "distance" },
        },
        .short_description = "Move carrier by a distance.",
        .long_description =
        \\Move given carrier by a provided distance. The carrier ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement. This command moves the carrier
        \\with speed profile feedback.
        ,
        .execute = &mclCarrierSpdMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_CARRIER_DISTANCE");
    try command.registry.put("WAIT_MOVE_CARRIER", .{
        .name = "WAIT_MOVE_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait for carrier movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given carrier is indicated as complete. If a timeout is specified, the 
        \\command will return an error if the waiting action takes longer than 
        \\the specified timeout duration. The timeout must be provided in 
        \\milliseconds.
        ,
        .execute = &mclWaitMoveCarrier,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put("PUSH_CARRIER_FORWARD", .{
        .name = "PUSH_CARRIER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Push carrier forward by carrier length.",
        .long_description =
        \\Push carrier forward with speed feedback-controlled movement. This
        \\movement targets a distance of the carrier length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the carrier. Specifying the optional
        \\`axis` parameter will push the carrier automatically when it arrives
        \\at the given axis; otherwise, the carrier will be pushed immediately
        \\from its current position.
        ,
        .execute = &mclCarrierPushForward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_FORWARD");
    try command.registry.put("PUSH_CARRIER_BACKWARD", .{
        .name = "PUSH_CARRIER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Push carrier backward by carrier length.",
        .long_description =
        \\Push carrier backward with speed feedback-controlled movement. This
        \\movement targets a distance of the carrier length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the carrier. Specifying the optional
        \\`axis` parameter will push the carrier automatically when it arrives
        \\at the given axis; otherwise, the carrier will be pushed immediately
        \\from its current position.
        ,
        .execute = &mclCarrierPushBackward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    try command.registry.put("PULL_CARRIER_FORWARD", .{
        .name = "PULL_CARRIER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
            .{ .name = "destination", .optional = true },
        },
        .short_description = "Pull incoming carrier forward at axis.",
        .long_description =
        \\Pull incoming carrier forward at axis. The pulled carrier's new ID
        \\must also be provided. If a destination in millimeters is specified,
        \\the carrier will automatically move to the destination after pull is
        \\completed.
        ,
        .execute = &mclCarrierPullForward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    try command.registry.put("PULL_CARRIER_BACKWARD", .{
        .name = "PULL_CARRIER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
            .{ .name = "destination", .optional = true },
        },
        .short_description = "Pull incoming carrier backward at axis.",
        .long_description =
        \\Pull incoming carrier backward at axis. The pulled carrier's new ID
        \\must also be provided. If a destination in millimeters is specified,
        \\the carrier will automatically move to the destination after pull is
        \\completed.
        ,
        .execute = &mclCarrierPullBackward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
    try command.registry.put("WAIT_PULL_CARRIER", .{
        .name = "WAIT_PULL_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait for carrier pull to complete.",
        .long_description =
        \\Pause the execution of any further commands until active carrier
        \\pull at the provided axis is indicated as complete. If a timeout is 
        \\specified, the command will return an error if the waiting action 
        \\takes longer than the specified timeout duration. The timeout must be 
        \\provided in milliseconds.
        ,
        .execute = &mclCarrierWaitPull,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_PULL_CARRIER");
    try command.registry.put("STOP_PULL_CARRIER", .{
        .name = "STOP_PULL_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Stop active carrier pull at axis.",
        .long_description =
        \\Stop active carrier pull at axis.
        ,
        .execute = &mclCarrierStopPull,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put("STOP_PUSH_CARRIER", .{
        .name = "STOP_PUSH_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Stop active carrier push at axis.",
        .long_description =
        \\Stop active carrier push at axis.
        ,
        .execute = &mclCarrierStopPush,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put("WAIT_AXIS_EMPTY", .{
        .name = "WAIT_AXIS_EMPTY",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait for axis to be empty.",
        .long_description =
        \\Pause the execution of any further commands until specified axis has
        \\no carriers, no active hall alarms, and no wait for push/pull. If a 
        \\timeout is specified, the command will return an error if the waiting 
        \\action takes longer than the specified timeout duration. The timeout 
        \\must be provided in milliseconds.
        ,
        .execute = &mclWaitAxisEmpty,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_AXIS_EMPTY");
    try command.registry.put("ADD_LOG_REGISTERS", .{
        .name = "ADD_LOG_REGISTERS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axes" },
            .{ .name = "registers" },
        },
        .short_description = "Add logging configuration for LOG_REGISTERS command.",
        .long_description =
        \\Setup the logging configuration for the specified line. This will
        \\overwrite the existing configuration for the specified line if any.
        \\It will log registers based on the given "registers" parameter on the
        \\station depending on the provided axes. Both "registers" and "axes"
        \\shall be provided as comma-separated values:
        \\
        \\"ADD_LOG_REGISTERS line_name 1,4,7 x,y"
        \\
        \\Both "registers" and "axes" accept "all" as the parameter to log every
        \\register and axes. The line configured for logging registers can be
        \\evaluated by "STATUS_LOG_REGISTERS" command.
        ,
        .execute = &addLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("ADD_LOG_REGISTERS");
    try command.registry.put("REMOVE_LOG_REGISTERS", .{
        .name = "REMOVE_LOG_REGISTERS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Remove the logging configuration for the specified line.",
        .long_description =
        \\Remove logging configuration for logging registers on the specified
        \\line.
        ,
        .execute = &removeLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("REMOVE_LOG_REGISTERS");
    try command.registry.put("RESET_LOG_REGISTERS", .{
        .name = "RESET_LOG_REGISTERS",
        .short_description = "Remove all logging configurations.",
        .long_description =
        \\Remove all logging configurations for logging registers for every
        \\line.
        ,
        .execute = &resetLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("RESET_LOG_REGISTERS");
    try command.registry.put("STATUS_LOG_REGISTERS", .{
        .name = "STATUS_LOG_REGISTERS",
        .short_description = "Print the logging configurations entry.",
        .long_description =
        \\Print the logging configuration for each line (if any). The status is
        \\given by "line_name:station_id:registers" with stations and registers
        \\are a comma-separated string.
        ,
        .execute = &statusLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("STATUS_LOG_REGISTERS");
    try command.registry.put("FILE_LOG_REGISTERS", .{
        .name = "FILE_LOG_REGISTERS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "path", .optional = true },
        },
        .short_description = "Create a logging file for the configured line.",
        .long_description =
        \\Create a log file for logging registers. If no logging configuration
        \\is detected, it will return an error value. If a path is not provided,
        \\a default log file containing all register values triggered by
        \\LOG_REGISTERS will be created in the current working directory as
        \\follows:
        \\"mmc-register-YYYY.MM.DD-HH.MM.SS.csv".
        \\
        \\Note that this command will not log any register value, the register
        \\will be logged by LOG_REGISTERS command.
        ,
        .execute = &pathLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("FILE_LOG_REGISTERS");
    try command.registry.put("LOG_REGISTERS", .{
        .name = "LOG_REGISTERS",
        .short_description = "Log the register values.",
        .long_description =
        \\This command will trigger the logging functionality on every line
        \\configured for logging the registers. It writes register values to
        \\the file specified by FILE_LOG_REGISTERS.
        ,
        .execute = &logRegisters,
    });
    errdefer _ = command.registry.orderedRemove("LOG_REGISTERS");
}

pub fn deinit() void {
    arena.deinit();
    line_names = undefined;
    if (log_file) |f| {
        f.close();
    }
    log_file = null;
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

fn mclAxisCarrier(params: [][]const u8) !void {
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

    const carrier_id = station.wr.carrier.axis(local_axis_index).id;

    if (carrier_id != 0) {
        std.log.info("Carrier {d} on axis {d}.\n", .{ carrier_id, axis_id });
        if (result_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                result_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{carrier_id}),
            );
        }
    } else {
        std.log.info("No carrier recognized on axis {d}.\n", .{axis_id});
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

    station.ww.axis = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0x5);
    // Reset on error as well as on success.
    defer station.resetY(0x5) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollWr();
        if (station.wr.carrier.axis(local_axis_index).state == .None) break;
    }
}

fn mclClearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line = mcl.lines[line_idx];
    if (params[1].len > 0) {
        const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
        const axis = line.axes[axis_index];
        const station = axis.station.*;

        station.ww.axis = axis.id.station;
        station.y.clear_errors = true;
        try station.send();
        defer station.sendY() catch {};
        defer station.y.clear_errors = false;
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX();
            if (station.x.errors_cleared) return;
        }
    }
    for (line.stations) |station| {
        station.y.clear_errors = true;
    }
    try line.send();
    wait_true: while (true) {
        try command.checkCommandInterrupt();
        for (line.stations) |station| {
            try station.pollX();
            if (station.x.errors_cleared == false) continue :wait_true;
        }
        break;
    }
    for (line.stations) |station| {
        station.y.clear_errors = false;
    }
    try line.sendY();
    wait_false: while (true) {
        try command.checkCommandInterrupt();
        for (line.stations) |station| {
            try station.pollX();
            if (station.x.errors_cleared == true) continue :wait_false;
        }
        break;
    }
}

fn mclReset(_: [][]const u8) !void {
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.reset_command_received = true;
            try station.sendY();
            while (true) {
                try command.checkCommandInterrupt();
                try station.pollX();
                if (!station.x.command_received) {
                    break;
                }
            }
        }
    }

    for (mcl.lines) |line| {
        @memset(line.ww, std.mem.zeroInit(mcl.registers.Ww, .{}));
        @memset(line.y, std.mem.zeroInit(mcl.registers.Y, .{}));
        try line.send();
    }
}

fn mclClearCarrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line = mcl.lines[line_idx];
    if (params[1].len > 0) {
        const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
        const axis = line.axes[axis_index];
        const station = axis.station.*;

        station.ww.axis = axis.id.station;
        station.y.axis_clear_carrier = true;
        try station.send();
        defer station.sendY() catch {};
        defer station.y.axis_clear_carrier = false;
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX();
            if (station.x.axis_cleared_carrier) return;
        }
    }
    for (line.stations) |station| {
        station.y.clear_carrier = true;
    }
    try line.sendY();
    wait_true: while (true) {
        try command.checkCommandInterrupt();
        for (line.stations) |station| {
            try station.pollX();
            if (station.x.cleared_carrier == false) continue :wait_true;
        }
        break;
    }
    for (line.stations) |station| {
        station.y.clear_carrier = false;
    }
    try line.sendY();
    wait_false: while (true) {
        try command.checkCommandInterrupt();
        for (line.stations) |station| {
            try station.pollX();
            if (station.x.cleared_carrier == true) continue :wait_false;
        }
        break;
    }
}

fn mclCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    const station = line.stations[0];
    try waitCommandReady(station);
    station.ww.command = .Calibration;
    station.ww.carrier = .{ .id = 1 };
    try sendCommand(station);
}

fn setLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    const station = line.stations[0];
    try waitCommandReady(station);
    station.ww.command = .SetLineZero;
    try sendCommand(station);
}

fn mclIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(u10, params[1], 0);

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

    const carrier_id: u10 = if (params[3].len > 0)
        try std.fmt.parseInt(u10, params[3], 0)
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
    station.ww.* = .{
        .command = if (dir == .forward)
            .IsolateForward
        else
            .IsolateBackward,
        .axis = local_axis + 1,
        .carrier = .{ .id = carrier_id },
    };
    if (link_axis) |a| {
        if (a == .backward) {
            station.ww.carrier.isolate_link_prev_axis = true;
        } else {
            station.ww.carrier.isolate_link_next_axis = true;
        }
    }
    defer {
        if (link_axis) |a| {
            if (a == .backward) {
                station.ww.carrier.isolate_link_prev_axis = false;
            } else {
                station.ww.carrier.isolate_link_next_axis = false;
            }
            station.sendWw() catch {};
        }
    }
    try sendCommand(station);
}

fn mclSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 3.0) return error.InvalidSpeed;

    const line_idx: usize = try matchLine(line_names, line_name);
    line_speeds[line_idx] = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(line_speeds[line_idx])) / 10.0,
    });
}

fn mclSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 19.6)
        return error.InvalidAcceleration;

    const line_idx: usize = try matchLine(line_names, line_name);
    line_accelerations[line_idx] = @intFromFloat(carrier_acceleration * 10.0);

    std.log.info("Set acceleration to {d}m/s^2.", .{
        @as(f32, @floatFromInt(line_accelerations[line_idx])) / 10.0,
    });
}

fn mclGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    std.log.info("Line {s} speed: {d}m/s", .{
        line_name,
        @as(f32, @floatFromInt(line_speeds[line_idx])) / 10.0,
    });
}

fn mclGetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    std.log.info(
        "Line {s} acceleration: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(line_accelerations[line_idx])) / 10.0,
        },
    );
}

fn mclCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main, _ =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;

    const station = main.station;

    const location: f32 = station.wr.carrier.axis(main.index.station).location;

    std.log.info(
        "Carrier {d} location: {d}mm",
        .{ carrier_id, location },
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

fn mclCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();

    var axis: mcl.Axis.Id.Line = 1;
    for (line.stations) |station| {
        for (0..3) |_local_axis| {
            const local_axis: mcl.Axis.Index.Station = @intCast(_local_axis);
            if (station.wr.carrier.axis(local_axis).id == carrier_id) {
                std.log.info(
                    "Carrier {d} axis: {}",
                    .{ carrier_id, axis },
                );
            }
            axis += 1;
            if (axis > line.axes.len) break;
        }
    }
}

fn mclHallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    var axis_id: u16 = 0;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(u16, params[1], 0);
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
    }

    if (axis_id > 0) {
        const axis = line.axes[axis_id - 1];
        const station = axis.station;
        try station.pollX();
        const alarms = station.x.hall_alarm.axis(axis.index.station);
        if (alarms.back) {
            std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis_id});
        }
        if (alarms.front) {
            std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis_id});
        }
        return;
    }

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
    const axis = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
    const side: mcl.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .backward
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .forward
        else
            return error.InvalidHallAlarmSide;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
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

fn mclCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line)) and
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .PositionMoveCarrierAxis,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .u32 = axis_id },
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main: mcl.Axis, const _aux: ?mcl.Axis =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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
            main.station.wr.carrier.axis(main.index.station).location;
        if (((direction == .forward and location > current_location) or
            (direction == .backward and location < current_location)) and
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .PositionMoveCarrierLocation,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .f32 = location },
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

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
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .PositionMoveCarrierDistance,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .f32 = distance },
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line)) and
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .SpeedMoveCarrierAxis,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .u32 = axis_id },
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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
            main.station.wr.carrier.axis(main.index.station).location;
        if (((direction == .forward and location > current_location) or
            (direction == .backward and location < current_location)) and
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .SpeedMoveCarrierLocation,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .f32 = location },
            .speed = line_speeds[line_idx],
            .acceleration = line_speeds[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

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
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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
            aux.station.wr.carrier.axis(aux.index.station).enabled)
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(station);

    station.ww.* = .{
        .command = .SpeedMoveCarrierDistance,
        .carrier = .{
            .id = carrier_id,
            .target = .{ .f32 = distance },
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = true,
        },
    };
    try sendCommand(station);
}

fn mclCarrierPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?mcl.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(mcl.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;

        const axis: mcl.Axis = line.axes[id - 1];

        try waitCommandReady(axis.station.*);
        axis.station.ww.* = .{
            .command = .PushTransitionForward,
            .axis = axis.id.station,
            .carrier = .{
                .id = carrier_id,
                .speed = line_speeds[line_idx],
                .acceleration = line_accelerations[line_idx],
                .enable_cas = false,
            },
        };
        try sendCommand(axis.station.*);
    } else {
        try line.pollWr();
        const main, const _aux =
            if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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

        station.ww.* = .{
            .command = .PushForward,
            .axis = main.index.station + 1,
            .carrier = .{
                .id = carrier_id,
                .speed = line_speeds[line_idx],
                .acceleration = line_accelerations[line_idx],
                .enable_cas = false,
            },
        };
        try sendCommand(station);
    }
}

fn mclCarrierPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?mcl.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(mcl.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;

        const axis: mcl.Axis = line.axes[id - 1];

        try waitCommandReady(axis.station.*);
        axis.station.ww.* = .{
            .command = .PushTransitionBackward,
            .axis = axis.id.station,
            .carrier = .{
                .id = carrier_id,
                .speed = line_speeds[line_idx],
                .acceleration = line_accelerations[line_idx],
                .enable_cas = false,
            },
        };
        try sendCommand(axis.station.*);
    } else {
        try line.pollWr();
        const main, const _aux =
            if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;
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

        station.ww.* = .{
            .command = .PushBackward,
            .axis = main.index.station + 1,
            .carrier = .{
                .id = carrier_id,
                .speed = line_speeds[line_idx],
                .acceleration = line_accelerations[line_idx],
                .enable_cas = false,
            },
        };
        try sendCommand(station);
    }
}

fn mclCarrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(station);
    station.ww.* = .{
        .command = .PullForward,
        .axis = local_axis + 1,
        .carrier = .{
            .id = carrier_id,
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = false,
        },
    };
    if (destination) |dest| {
        station.ww.command = .PullTransitionLocationForward;
        station.ww.carrier.target = .{ .f32 = dest };
        station.ww.carrier.enable_cas = true;
    }
    try sendCommand(station);
}

fn mclCarrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(station);
    station.ww.* = .{
        .command = .PullBackward,
        .axis = local_axis + 1,
        .carrier = .{
            .id = carrier_id,
            .speed = line_speeds[line_idx],
            .acceleration = line_accelerations[line_idx],
            .enable_cas = false,
        },
    };
    if (destination) |dest| {
        station.ww.command = .PullTransitionLocationBackward;
        station.ww.carrier.target = .{ .f32 = dest };
        station.ww.carrier.enable_cas = true;
    }
    try sendCommand(station);
}

fn mclCarrierWaitPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(i16, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        try station.pollX();
        try station.pollWr();
        const carrier_state = station.wr.carrier.axis(local_axis).state;
        if (carrier_state == .PullForwardCompleted or
            carrier_state == .PullBackwardCompleted) break;
    }
}

fn mclCarrierStopPull(params: [][]const u8) !void {
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
        if (!station.x.wait_pull_carrier.axis(local_axis)) break;
    }
}

fn mclCarrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis = line.axes[axis_id - 1];

    axis.station.y.reset_push_carrier.setAxis(axis.index.station, true);
    try axis.station.sendY();
    defer {
        axis.station.y.reset_push_carrier.setAxis(axis.index.station, false);
        axis.station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try axis.station.pollX();
        if (!axis.station.x.wait_push_carrier.axis(axis.index.station)) break;
    }
}

fn mclWaitAxisEmpty(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis: mcl.Axis = line.axes[axis_id - 1];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        try axis.station.pollX();
        try axis.station.pollWr();
        const carrier = axis.station.wr.carrier.axis(axis.index.station);
        const axis_alarms = axis.station.x.hall_alarm.axis(axis.index.station);
        if (carrier.id == 0 and !axis_alarms.back and !axis_alarms.front and
            !axis.station.x.wait_pull_carrier.axis(axis.index.station) and
            !axis.station.x.wait_push_carrier.axis(axis.index.station))
        {
            break;
        }
    }
}

fn mclWaitMoveCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        try line.pollWr();
        const main, _ = if (line.search(carrier_id)) |t| t
            // Do not error here as the poll receiving CC-Link information can
            // "move past" a backwards traveling carrier during transmission, thus
            // rendering the carrier briefly invisible in the whole loop.
            else continue;
        const station = main.station.*;
        const wr = station.wr;

        if (wr.carrier.axis(main.index.station).state == .PosMoveCompleted or
            wr.carrier.axis(main.index.station).state == .SpdMoveCompleted)
        {
            break;
        }

        if (main.id.line < line.axes.len) {
            const next_axis_index = @rem(main.index.station + 1, 3);
            const next_station = if (next_axis_index == 0)
                line.stations[station.index + 1]
            else
                station;
            const carrier_number =
                next_station.wr.carrier.axis(next_axis_index).id;
            const carrier_state =
                next_station.wr.carrier.axis(next_axis_index).state;
            if (carrier_number == carrier_id and
                (carrier_state == .PosMoveCompleted or
                    carrier_state == .SpdMoveCompleted))
            {
                break;
            }
        }
    }
}

/// Add logging configuration for registers logging in the specified line
fn addLogRegisters(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];

    var log: LogLine = std.mem.zeroInit(LogLine, .{});

    // Validate "axes" parameter
    var axis_input_iterator = std.mem.tokenizeSequence(u8, params[1], ",");
    while (axis_input_iterator.next()) |token| {
        if (std.ascii.eqlIgnoreCase("all", token)) {
            for (0..line.stations.len) |i| {
                log.stations[i] = true;
            }
            break;
        }
        const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, token, 0);

        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
        const station_index: Station.Index = @intCast(axis_index / 3);
        log.stations[station_index] = true;
    }

    // Validate "registers" parameter
    var reg_input_iterator = std.mem.tokenizeSequence(u8, params[2], ",");
    outer: while (reg_input_iterator.next()) |token| {
        if (std.ascii.eqlIgnoreCase("all", token)) {
            inline for (@typeInfo(LogLine.RegisterType).@"enum".fields) |field| {
                log.registers.set(@enumFromInt(field.value), true);
            }
            break;
        }
        inline for (@typeInfo(LogLine.RegisterType).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, token)) {
                log.registers.set(@enumFromInt(field.value), true);
                continue :outer;
            }
        }
        return error.InvalidRegister;
    }
    var info_buffer: [64]u8 = undefined;
    const prefix = "Ready to log registers: ";
    @memcpy(info_buffer[0..prefix.len], prefix);
    var buf_len = prefix.len;

    var register_iterator = log.registers.iterator();
    while (register_iterator.next()) |reg_entry| {
        if (!log.registers.get(reg_entry.key)) continue;
        const reg_tag: []const u8 = @tagName(reg_entry.key);
        @memcpy(
            info_buffer[buf_len .. buf_len + reg_tag.len],
            @tagName(reg_entry.key),
        );
        @memcpy(
            info_buffer[buf_len + reg_tag.len .. buf_len + reg_tag.len + 1],
            ",",
        );
        buf_len += reg_tag.len + 1;
    }
    std.log.info("{s}", .{info_buffer[0 .. buf_len - 1]});
    log.status = true;
    log_lines[line_idx] = log;
}

fn removeLogRegisters(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(line_names, line_name);

    if (log_lines[line_idx].status == false) {
        std.log.err("Line is not configured for logging yet", .{});
        return;
    }

    log_lines[line_idx].status = false;
}

fn resetLogRegisters(_: [][]const u8) !void {
    for (0..line_names.len) |i| {
        log_lines[i].status = false;
    }
    log_file = null;
    log_time_start = 0;
}

fn statusLogRegisters(_: [][]const u8) !void {
    var buffer: [8192]u8 = undefined;
    var buf_len: usize = 0;
    // flag to indicate printing ","
    var first = true;
    for (0..line_names.len) |line_idx| {
        // Section to print line name
        if (log_lines[line_idx].status == false) continue;
        buf_len += (try std.fmt.bufPrint(
            buffer[buf_len..],
            "{s}:",
            .{line_names[line_idx]},
        )).len;
        // Section to print station index
        first = true;
        for (0..log_lines[line_idx].stations.len) |station_idx| {
            if (log_lines[line_idx].stations[station_idx] == false) continue;
            if (!first) {
                buf_len += (try std.fmt.bufPrint(
                    buffer[buf_len..],
                    "{s}",
                    .{","},
                )).len;
            }
            buf_len += std.fmt.formatIntBuf(
                buffer[buf_len..],
                station_idx + 1,
                10,
                .lower,
                .{},
            );
            first = false;
        }
        buf_len += (try std.fmt.bufPrint(
            buffer[buf_len..],
            "{s}",
            .{":"},
        )).len;
        // Section to print register
        first = true;
        var reg_iterator = log_lines[line_idx].registers.iterator();
        while (reg_iterator.next()) |reg_entry| {
            if (reg_entry.value.* == false) continue;
            if (!first) {
                buf_len += (try std.fmt.bufPrint(
                    buffer[buf_len..],
                    "{s}",
                    .{","},
                )).len;
            }
            buf_len += (try std.fmt.bufPrint(
                buffer[buf_len..],
                "{s}",
                .{@tagName(reg_entry.key)},
            )).len;
            first = false;
        }
        buf_len += (try std.fmt.bufPrint(
            buffer[buf_len..],
            "{s}",
            .{"\n"},
        )).len;
    }
    std.log.info("{s}", .{buffer[0..buf_len]});
}

fn pathLogRegisters(params: [][]const u8) !void {
    var log_registers_initialized = false;
    for (0..line_names.len) |line_idx| {
        if (log_lines[line_idx].status == true) {
            log_registers_initialized = true;
            break;
        }
    }
    if (!log_registers_initialized) {
        std.log.err("Logging is not configured for any line", .{});
        return;
    }
    const path = params[0];
    var path_buffer: [512]u8 = undefined;
    log_time_start = 0;
    const file_path = if (path.len > 0) path else p: {
        var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(timestamp / std.time.s_per_day);
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(timestamp % std.time.s_per_day);
        const time = try chrono.Time.fromNumSecondsFromMidnight(time_day, 0);

        break :p try std.fmt.bufPrint(
            &path_buffer,
            "mmc-register-{}.{:0>2}.{:0>2}-{:0>2}.{:0>2}.{:0>2}.csv",
            .{
                ymd.year,
                ymd.month.number(),
                ymd.day,
                time.hour(),
                time.minute(),
                time.second(),
            },
        );
    };
    std.log.info("The registers will be logged to {s}", .{file_path});
    log_file = try std.fs.cwd().createFile(file_path, .{});

    if (log_file) |f| {
        try std.fmt.format(f, "timestamp,", .{});
        for (line_names) |line_name| {
            const line_idx = try matchLine(line_names, line_name);
            if (log_lines[line_idx].status == false) continue;
            for (0..256) |station_idx| {
                if (log_lines[line_idx].stations[station_idx] == false) continue;
                var reg_iterator = log_lines[line_idx].registers.iterator();
                while (reg_iterator.next()) |reg_entry| {
                    const reg_type = @TypeOf(reg_entry.key);
                    inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                        if (@intFromEnum(reg_entry.key) == reg_enum.value and
                            reg_entry.value.* == true)
                        {
                            var _buffer: [64]u8 = undefined;
                            try registerFieldToString(
                                f.writer(),
                                try std.fmt.bufPrint(
                                    &_buffer,
                                    "{s}_station{d}_{s}",
                                    .{ line_name, station_idx + 1, reg_enum.name },
                                ),
                                "",
                                @FieldType(
                                    Registers,
                                    reg_enum.name,
                                ),
                            );
                            break;
                        }
                    }
                }
            }
        }
        try f.writer().writeByte('\n');
    }
}

/// Write the register values to the logging file specified by
/// line_name parameter. If the line has not ben set for logging,
/// it will return error.
fn logRegisters(_: [][]const u8) !void {
    log_time_start = if (log_time_start == 0) std.time.microTimestamp() else log_time_start;
    if (log_file) |f| {
        const timestamp = @as(f64, @floatFromInt(std.time.microTimestamp() - log_time_start)) / 1_000_000;
        try f.writer().print("{d},", .{timestamp});
        for (line_names) |line| {
            const line_idx = try matchLine(line_names, line);
            if (log_lines[line_idx].status == false) continue;
            for (0..256) |station_idx| {
                if (log_lines[line_idx].stations[station_idx] == false) continue;
                var reg_iterator = log_lines[line_idx].registers.iterator();
                while (reg_iterator.next()) |reg_entry| {
                    const reg_type = @TypeOf(reg_entry.key);
                    inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                        if (@intFromEnum(reg_entry.key) == reg_enum.value and
                            reg_entry.value.* == true)
                        {
                            switch (reg_entry.key) {
                                .x => try mcl.lines[line_idx].stations[station_idx].pollX(),
                                .y => try mcl.lines[line_idx].stations[station_idx].pollY(),
                                .wr => try mcl.lines[line_idx].stations[station_idx].pollWr(),
                                .ww => try mcl.lines[line_idx].stations[station_idx].pollWw(),
                            }
                            try registerValueToString(
                                f.writer(),
                                @field(
                                    mcl.lines[line_idx].stations[station_idx],
                                    reg_enum.name,
                                ),
                            );
                            break;
                        }
                    }
                }
            }
            if (log_lines[line_idx].status) {}
        }
        try f.writer().writeByte('\n');
    } else {
        std.log.err("Logging file not configured", .{});
        return;
    }
}

/// Write register fields name into the logging file.
fn registerFieldToString(
    f: std.fs.File.Writer,
    prefix: []const u8,
    comptime parent: []const u8,
    comptime ParentType: type,
) !void {
    inline for (@typeInfo(ParentType).@"struct".fields) |child_field| {
        if (child_field.name[0] == '_') continue;
        if (@typeInfo(child_field.type) == .@"struct") {
            if (parent.len == 0) {
                try registerFieldToString(
                    f,
                    prefix,
                    child_field.name,
                    child_field.type,
                );
            } else {
                try registerFieldToString(
                    f,
                    prefix,
                    parent ++ "." ++ child_field.name,
                    child_field.type,
                );
            }
        } else {
            if (parent.len == 0) {
                try std.fmt.format(
                    f,
                    "{s}_{s},",
                    .{ prefix, child_field.name },
                );
            } else {
                if (@typeInfo(child_field.type) == .@"union") {
                    const ti = @typeInfo(child_field.type).@"union";
                    inline for (ti.fields) |union_field| {
                        try std.fmt.format(
                            f,
                            "{s}_{s},",
                            .{ prefix, parent ++ "." ++ child_field.name ++ "." ++ union_field.name },
                        );
                    }
                } else {
                    try std.fmt.format(
                        f,
                        "{s}_{s},",
                        .{ prefix, parent ++ "." ++ child_field.name },
                    );
                }
            }
        }
    }
}

// Write register values into the logging file
fn registerValueToString(f: std.fs.File.Writer, parent_field: anytype) !void {
    const parent_type = @TypeOf(parent_field.*);
    inline for (@typeInfo(parent_type).@"struct".fields) |child_field| {
        if (child_field.name[0] == '_') continue;
        if (comptime @typeInfo(child_field.type) == .@"struct") {
            try registerValueToString(
                f,
                &@field(parent_field.*, child_field.name),
            );
        } else {
            const child_value = @field(parent_field.*, child_field.name);
            if (comptime @typeInfo(@TypeOf(child_value)) == .@"enum") {
                try f.print("{d},", .{@intFromEnum(child_value)});
            } else if (comptime @typeInfo(child_field.type) == .@"union") {
                const ti = @typeInfo(child_field.type).@"union";
                inline for (ti.fields) |union_field| {
                    const union_val = @field(child_value, union_field.name);
                    if (@typeInfo(@TypeOf(union_val)) == .float) {
                        try f.print("{d},", .{union_val});
                    } else try f.print("{},", .{union_val});
                }
            } else {
                if (@typeInfo(@TypeOf(child_value)) == .float) {
                    try f.print("{d},", .{child_value});
                } else try f.print("{},", .{child_value});
            }
        }
    }
}

fn matchLine(names: [][]u8, name: []const u8) !usize {
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
        if (station.x.command_ready) break;
    }
}

fn sendCommand(station: Station) !void {
    std.log.debug("Sending command...", .{});
    while (true) {
        try command.checkCommandInterrupt();
        try station.sendWw();
        try station.setY(0x1);
        errdefer station.resetY(0x1) catch {};
        try station.pollX();
        if (station.x.command_received) {
            break;
        }
    }
    try station.resetY(0x1);

    try station.pollWr();
    const command_response = station.wr.command_response;

    std.log.debug("Resetting command received flag...", .{});
    while (true) {
        try command.checkCommandInterrupt();
        try station.setY(0x2);
        errdefer station.resetY(0x2) catch {};
        try station.pollX();
        if (!station.x.command_received) {
            try station.resetY(0x2);
            break;
        }
    }

    return switch (command_response) {
        .NoError => {},
        .InvalidCommand => error.InvalidCommand,
        .CarrierNotFound => error.CarrierNotFound,
        .HomingFailed => error.HomingFailed,
        .InvalidParameter => error.InvalidParameter,
        .InvalidSystemState => error.InvalidSystemState,
        .CarrierAlreadyExists => error.CarrierAlreadyExists,
        .InvalidAxis => error.InvalidAxis,
    };
}
