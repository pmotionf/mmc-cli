const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const chrono = @import("chrono");
const CircularBufferAlloc =
    @import("../circular_buffer.zig").CircularBufferAlloc;

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u5 = undefined;
var line_accelerations: []u8 = undefined;

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

const Registers = packed struct {
    x: mcl.registers.X,
    y: mcl.registers.Y,
    wr: mcl.registers.Wr,
    ww: mcl.registers.Ww,
};

const LoggingRegisters = struct {
    timestamp: f64,
    /// The maximum number of stations is 64 * 4
    registers: [64 * 4]Registers,
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

    try command.registry.put(.{
        .name = "MCL_VERSION",
        .short_description = "Display the version of MCL.",
        .long_description =
        \\Print the currently linked version of the PMF Motion Control Library
        \\in Semantic Version format.
        ,
        .execute = &mclVersion,
    });
    errdefer command.registry.orderedRemove("MCL_VERSION");
    try command.registry.put(.{
        .name = "CONNECT",
        .short_description = "Connect MCL with motion system.",
        .long_description =
        \\Initialize MCL's connection with the motion system. This command
        \\should be run before any other MCL command, and also after any power
        \\cycle of the motion system.
        ,
        .execute = &mclConnect,
    });
    errdefer command.registry.orderedRemove("CONNECT");
    try command.registry.put(.{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End MCL's connection with the motion system. This command should be
        \\run after other MCL commands are completed.
        ,
        .execute = &mclDisconnect,
    });
    errdefer command.registry.orderedRemove("DISCONNECT");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SET_SPEED");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SET_ACCELERATION");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("GET_SPEED");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PRINT_X");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PRINT_Y");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PRINT_WR");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PRINT_WW");
    try command.registry.put(.{
        .name = "AXIS_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{
                .name = "result variable",
                .optional = true,
                .resolve = false,
            },
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
    try command.registry.put(.{
        .name = "ASSERT_CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "location" },
            .{ .name = "threshold", .optional = true },
        },
        .short_description = "Check that a carrier is on the expected location.",
        .long_description =
        \\Throw an error if the carrier is not located on the specified location
        \\within the threshold. The default threshold value is 1 mm. Both the
        \\location and threshold must be provided in millimeters.
        ,
        .execute = &mclAssertLocation,
    });
    try command.registry.put(.{
        .name = "CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{
                .name = "result variable",
                .resolve = false,
                .optional = true,
            },
        },
        .short_description = "Display a carrier's location.",
        .long_description =
        \\Print a given carrier's location if it is currently recognized in
        \\the provided line. If a result variable name is provided, then store
        \\the carrier's location in the variable.
        ,
        .execute = &mclCarrierLocation,
    });
    errdefer command.registry.orderedRemove("CARRIER_LOCATION");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("CARRIER_AXIS");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("HALL_STATUS");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(.{
        .name = "RESET_MCL",
        .short_description = "Reset all MCL registers.",
        .long_description =
        \\Reset all write registers (Y and Ww registers).
        ,
        .execute = &mclReset,
    });
    errdefer command.registry.orderedRemove("RESET_MCL");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("CALIBRATE");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SET_LINE_ZERO");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("ISOLATE");
    try command.registry.put(.{
        .name = "WAIT_ISOLATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait for carrier isolation to complete.",
        .long_description =
        \\Pause the execution of any further commands until the isolation of the
        \\given carrier is indicated as complete. If a timeout is specified, the
        \\command will return an error if the waiting action takes longer than
        \\the specified timeout duration. The timeout must be provided in
        \\milliseconds.
        ,
        .execute = &mclWaitIsolate,
    });
    errdefer command.registry.orderedRemove("WAIT_ISOLATE");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("MOVE_CARRIER_AXIS");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("MOVE_CARRIER_LOCATION");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("MOVE_CARRIER_DISTANCE");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_AXIS");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_LOCATION");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_DISTANCE");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PUSH_CARRIER_FORWARD");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("WAIT_PULL_CARRIER");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("STOP_PUSH_CARRIER");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("WAIT_AXIS_EMPTY");
    try command.registry.put(.{
        .name = "ADD_LOG_REGISTERS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axes" },
            .{ .name = "registers" },
        },
        .short_description = "Add registers logging configuration.",
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
    errdefer command.registry.orderedRemove("ADD_LOG_REGISTERS");
    try command.registry.put(.{
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
    errdefer command.registry.orderedRemove("REMOVE_LOG_REGISTERS");
    try command.registry.put(.{
        .name = "RESET_LOG_REGISTERS",
        .short_description = "Remove all logging configurations.",
        .long_description =
        \\Remove all logging configurations for logging registers for every
        \\line.
        ,
        .execute = &resetLogRegisters,
    });
    errdefer command.registry.orderedRemove("RESET_LOG_REGISTERS");
    try command.registry.put(.{
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
    try command.registry.put(.{
        .name = "START_LOG_REGISTERS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "duration" },
            .{ .name = "path", .optional = true },
        },
        .short_description = "Start the logging and save the file upon cancellation.",
        .long_description =
        \\Start the registers logging process. The log file will always contain
        \\only the most recent data covering the specified duration (in seconds).
        \\The Logging runs until cancelled manually (Ctrl+C). This command returns
        \\an error if no lines have been configured to be logged. If no path is
        \\provided, a default log file containing all register values will be
        \\created in the current working directory as:
        \\    "mmc-register-YYYY.MM.DD-HH.MM.SS.csv".
        ,
        .execute = &startLogRegisters,
    });
    errdefer _ = command.registry.orderedRemove("START_LOG_REGISTERS");
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

fn mclWaitIsolate(params: [][]const u8) !void {
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

        if (wr.carrier.axis(main.index.station).state == .BackwardIsolationCompleted or
            wr.carrier.axis(main.index.station).state == .ForwardIsolationCompleted)
        {
            break;
        }
    }
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

fn mclAssertLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const expected_location: f32 = try std.fmt.parseFloat(f32, params[2]);
    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line: mcl.Line = mcl.lines[line_idx];
    try line.pollWr();
    const main: mcl.Axis, _ =
        if (line.search(carrier_id)) |t| t else return error.CarrierNotFound;

    const station = main.station;

    const location: f32 = station.wr.carrier.axis(main.index.station).location;
    // Default location threshold value is 1 mm
    const location_thr = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        1.0;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
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

fn startLogRegisters(params: [][]const u8) !void {
    const log_duration = try std.fmt.parseFloat(f64, params[0]);
    // Assumption: The registers value is updated every 3 ms
    const logging_size_float =
        log_duration * @as(f64, @floatFromInt(std.time.ms_per_s)) / 3.0;
    if (std.math.isNan(logging_size_float) or
        std.math.isInf(logging_size_float) or
        !std.math.isFinite(logging_size_float)) return error.InvalidDuration;

    const logging_size =
        @as(usize, @intFromFloat(@round(logging_size_float)));

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
    const path = params[1];
    var path_buffer: [512]u8 = undefined;
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
    const log_file = try std.fs.cwd().createFile(file_path, .{});
    // _buf is used to print the title prefix with std.fmt.bufPrint()
    var _buf: [1_024]u8 = undefined;

    const log_writer = log_file.writer();
    try log_writer.print("timestamp,", .{});

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
                        try writeLoggingHeaders(
                            log_writer,
                            try std.fmt.bufPrint(
                                &_buf,
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

    var logging_data =
        try CircularBufferAlloc(LoggingRegisters).initCapacity(
            allocator,
            logging_size,
        );
    const log_time_start = std.time.microTimestamp();
    std.log.info("logging registers data..", .{});
    var timer = try std.time.Timer.start();
    while (true) {
        command.checkCommandInterrupt() catch {
            std.log.info("saving logging data..", .{});
            break;
        };
        logging_data.writeItemOverwrite(try logRegisters(
            log_time_start,
            &timer,
        ));
    }
    try logToString(
        &logging_data,
        log_writer,
    );
    defer logging_data.deinit();
}

/// Convert the logged binary data to string and save it to the logging file
fn logToString(
    logging_data: *CircularBufferAlloc(LoggingRegisters),
    writer: std.fs.File.Writer,
) !void {
    while (logging_data.readItem()) |item| {
        // Copy a newline in every logging data entry
        try writer.writeByte('\n');
        // write timestamp to the buffer
        try writer.print("{d},", .{item.timestamp});

        var reg_idx: usize = 0;
        for (line_names) |line_name| {
            const line_idx = try matchLine(line_names, line_name);
            if (log_lines[line_idx].status == false) continue;
            for (0..256) |station_idx| {
                if (log_lines[line_idx].stations[station_idx] == false) continue;
                var reg_iterator = log_lines[line_idx].registers.iterator();
                var command_code: mcl.registers.Ww.Command = .None;
                while (reg_iterator.next()) |reg_entry| {
                    const reg_type = @TypeOf(reg_entry.key);
                    inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                        if (@intFromEnum(reg_entry.key) == reg_enum.value and
                            reg_entry.value.* == true)
                        {
                            try registerValueToString(
                                @field(
                                    item.registers[reg_idx],
                                    reg_enum.name,
                                ),
                                writer,
                                &command_code,
                            );
                            reg_idx += 1;
                            break;
                        }
                    }
                }
            }
        }
    }
}

// Write register values into the string
fn registerValueToString(
    parent: anytype,
    writer: std.fs.File.Writer,
    command_code: *mcl.registers.Ww.Command,
) !void {
    var binary_buf_idx: usize = 0;
    const parent_ti = @typeInfo(@TypeOf(parent)).@"struct";
    inline for (parent_ti.fields) |child_field| {
        if (child_field.name[0] == '_') {
            binary_buf_idx += @bitSizeOf(child_field.type);
            continue;
        }
        if (comptime @typeInfo(child_field.type) == .@"struct") {
            try registerValueToString(
                @field(parent, child_field.name),
                writer,
                command_code,
            );
        } else {
            if (comptime @typeInfo(child_field.type) == .@"enum") {
                const child_value = @field(parent, child_field.name);
                if (child_field.type == mcl.registers.Ww.Command) {
                    command_code.* = child_value;
                }
                try writer.print("{d},", .{@intFromEnum(child_value)});
            } else if (comptime @typeInfo(child_field.type) == .@"union") {
                const child_value = @field(parent, child_field.name);
                const ti = @typeInfo(child_field.type).@"union";
                inline for (ti.fields) |union_field| {
                    const union_val = @field(child_value, union_field.name);
                    switch (command_code.*) {
                        .SpeedMoveCarrierAxis,
                        .PositionMoveCarrierAxis,
                        => {
                            if (@typeInfo(@TypeOf(union_val)) == .int) {
                                try writer.print("{},", .{union_val});
                            } else {
                                try writer.print("0,", .{});
                            }
                        },
                        .SpeedMoveCarrierDistance,
                        .SpeedMoveCarrierLocation,
                        .PositionMoveCarrierDistance,
                        .PositionMoveCarrierLocation,
                        .PullTransitionLocationBackward,
                        .PullTransitionLocationForward,
                        => {
                            if (@typeInfo(@TypeOf(union_val)) == .float) {
                                try writer.print("{d},", .{union_val});
                            } else {
                                try writer.print("0,", .{});
                            }
                        },
                        else => try writer.print("0,", .{}),
                    }
                }
            } else {
                const child_value = @field(parent, child_field.name);
                if (@typeInfo(@TypeOf(child_value)) == .float) {
                    try writer.print("{d},", .{child_value});
                } else try writer.print("{},", .{child_value});
            }
        }
    }
}

/// Log the registers value. The registers value is logged in binary data, but
/// saved into slice of bytes
fn logRegisters(log_time_start: i64, timer: *std.time.Timer) !LoggingRegisters {
    while (timer.read() < 3 * std.time.ns_per_ms) {}
    const timestamp = @as(f64, @floatFromInt(std.time.microTimestamp() - log_time_start)) / 1_000_000;
    timer.reset();
    var result: LoggingRegisters = undefined;
    result.timestamp = timestamp;

    var reg_idx: usize = 0;
    for (line_names) |line_name| {
        const line_idx = try matchLine(line_names, line_name);
        if (log_lines[line_idx].status == false) continue;
        const line = mcl.lines[line_idx];
        for (0..256) |station_idx| {
            if (log_lines[line_idx].stations[station_idx] == false) continue;
            const station = line.stations[station_idx];
            var reg_iterator = log_lines[line_idx].registers.iterator();
            while (reg_iterator.next()) |reg_entry| {
                const reg_type = @TypeOf(reg_entry.key);
                inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                    if (@intFromEnum(reg_entry.key) == reg_enum.value and
                        reg_entry.value.* == true)
                    {
                        switch (reg_entry.key) {
                            .x => {
                                try mcl.lines[line_idx].stations[station_idx].pollX();
                                result.registers[reg_idx].x = station.x.*;
                            },
                            .y => {
                                try mcl.lines[line_idx].stations[station_idx].pollY();
                                result.registers[reg_idx].y = station.y.*;
                            },
                            .wr => {
                                try mcl.lines[line_idx].stations[station_idx].pollWr();
                                result.registers[reg_idx].wr = station.wr.*;
                            },
                            .ww => {
                                try mcl.lines[line_idx].stations[station_idx].pollWw();
                                result.registers[reg_idx].ww = station.ww.*;
                            },
                        }
                        reg_idx += 1;
                        break;
                    }
                }
            }
        }
    }
    return result;
}

/// Write the register field to a buffer. Return the number of bytes used.
fn writeLoggingHeaders(
    writer: anytype,
    prefix: []const u8,
    comptime parent: []const u8,
    comptime ParentType: type,
) !void {
    inline for (@typeInfo(ParentType).@"struct".fields) |child_field| {
        if (child_field.name[0] == '_') continue;
        if (@typeInfo(child_field.type) == .@"struct") {
            if (parent.len == 0) {
                try writeLoggingHeaders(
                    writer,
                    prefix,
                    child_field.name,
                    child_field.type,
                );
            } else {
                try writeLoggingHeaders(
                    writer,
                    prefix,
                    parent ++ "." ++ child_field.name,
                    child_field.type,
                );
            }
        } else {
            if (parent.len == 0) {
                try writer.print(
                    "{s}_{s},",
                    .{ prefix, child_field.name },
                );
            } else {
                if (@typeInfo(child_field.type) == .@"union") {
                    const ti = @typeInfo(child_field.type).@"union";
                    inline for (ti.fields) |union_field| {
                        try writer.print(
                            "{s}_{s},",
                            .{ prefix, parent ++ "." ++ child_field.name ++ "." ++ union_field.name },
                        );
                    }
                } else {
                    try writer.print(
                        "{s}_{s},",
                        .{ prefix, parent ++ "." ++ child_field.name },
                    );
                }
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
    switch (station.ww.command) {
        .PositionMoveCarrierAxis,
        .PositionMoveCarrierDistance,
        .PositionMoveCarrierLocation,
        .SpeedMoveCarrierAxis,
        .SpeedMoveCarrierDistance,
        .SpeedMoveCarrierLocation,
        .PullTransitionLocationBackward,
        .PullTransitionLocationForward,
        => {},
        else => {
            station.ww.carrier.target = .{ .u32 = 0 };
        },
    }
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

fn testWriteLoggingHeaders(
    comptime prefix: []const u8,
    comptime parent: []const u8,
    comptime ParentType: type,
) ![]const u8 {
    comptime var result: []const u8 = "";
    inline for (@typeInfo(ParentType).@"struct".fields) |child_field| {
        if (child_field.name[0] == '_') continue;
        if (@typeInfo(child_field.type) == .@"struct") {
            result = result ++ try testWriteLoggingHeaders(
                prefix,
                parent ++ "." ++ child_field.name,
                child_field.type,
            );
        } else {
            if (@typeInfo(child_field.type) == .@"union") {
                const ti = @typeInfo(child_field.type).@"union";
                inline for (ti.fields) |union_field| {
                    result = result ++ std.fmt.comptimePrint(
                        "{s}_{s},",
                        .{ prefix, parent ++ "." ++ child_field.name ++ "." ++ union_field.name },
                    );
                }
            } else {
                result = result ++ std.fmt.comptimePrint(
                    "{s}_{s},",
                    .{ prefix, parent ++ "." ++ child_field.name },
                );
            }
        }
    }
    return result;
}

test "writeLoggingHeaders" {
    const ti = @typeInfo(mcl.registers).@"struct";
    inline for (ti.decls) |decl| {
        // only taking the registers declaration
        if (comptime decl.name.len > 2) continue;
        // Get the expected result
        comptime var expected: []const u8 = "";
        const register = @field(mcl.registers, decl.name);
        const register_ti = @typeInfo(register).@"struct";
        inline for (register_ti.fields) |reg_field| {
            if (reg_field.name[0] == '_') continue;
            if (@typeInfo(reg_field.type) == .@"struct") {
                expected = expected ++ comptime try testWriteLoggingHeaders(
                    std.fmt.comptimePrint(
                        "{s}",
                        .{decl.name},
                    ),
                    reg_field.name,
                    reg_field.type,
                );
            } else {
                expected = expected ++ std.fmt.comptimePrint(
                    "{s}_{s},",
                    .{ decl.name, reg_field.name },
                );
            }
        }
        var buffer: [expected.len]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        writeLoggingHeaders(
            writer,
            std.fmt.comptimePrint("{s}", .{decl.name}),
            "",
            register,
        ) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            return e;
        };
        std.testing.expectEqualStrings(&buffer, expected) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            return e;
        };
    }
}
