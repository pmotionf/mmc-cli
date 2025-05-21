const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");
const mcl = @import("mcl");
const mmc = @import("mmc_config");
const protobuf_msg = mmc.protobuf_msg;
const protobuf = mmc.protobuf;
const SendCommand = protobuf_msg.SendCommand;
const CarrierStatus = protobuf_msg.CarrierStatus;
const HallStatus = protobuf_msg.HallStatus;
const Direction = protobuf_msg.Direction;
const network = @import("network");

const CircularBufferAlloc =
    @import("../circular_buffer.zig").CircularBufferAlloc;
const command = @import("../command.zig");

const LogLine = struct {
    /// Flag if line is configured for logging or not
    status: bool,
    /// Specify which registers to log for each line
    registers: std.EnumArray(RegisterType, bool),
    /// Flag which stations to be logged based on axes provided by user
    stations: [256]bool,
};

const RegisterType = enum { x, y, wr, ww };

const RegisterTypeCap = enum { X, Y, Wr, Ww };

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

// TODO: Decide the value properly
var fba_buffer: [1_024_000]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const fba_allocator = fba.allocator();

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u5 = undefined;
var line_accelerations: []u8 = undefined;
var IP_address: []u8 = undefined;
var port: u16 = undefined;

pub var main_socket: ?network.Socket = null;

pub const Config = struct {
    IP_address: []u8,
    port: u16,
};

pub fn init(c: Config) !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    try network.init();
    errdefer network.deinit();
    IP_address = try allocator.alloc(u8, c.IP_address.len);
    @memcpy(IP_address, c.IP_address);
    port = c.port;
    std.log.debug("{s}, {}", .{
        IP_address,
        port,
    });
    try command.registry.put(.{
        .name = "SERVER_VERSION",
        .short_description = "Display the version of the MMC server",
        .long_description =
        \\Print the currently running version of the MMC server in Semantic
        \\Version format.
        ,
        .execute = &serverVersion,
    });
    errdefer command.registry.orderedRemove("SERVER_VERSION");
    try command.registry.put(.{
        .name = "CONNECT",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "port", .optional = true },
            .{ .name = "IP address", .optional = true },
        },
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file. The port
        \\and IP address can be overwritten by providing the new port and IP
        \\address to this command.
        ,
        .execute = &clientConnect,
    });
    errdefer command.registry.orderedRemove("CONNECT");
    try command.registry.put(.{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End connection with the mmc server.
        ,
        .execute = &clientDisconnect,
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
        .execute = &clientSetSpeed,
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
        .execute = &clientSetAcceleration,
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
        \\by its name. Acceleration is in meters-per-second-squared.
        ,
        .execute = &clientGetSpeed,
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
        \\referenced by its name. The acceleration is a whole integer number
        \\between 1 and 100, inclusive.
        ,
        .execute = &clientGetAcceleration,
    });
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
        .name = "PRINT_X",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Print the X register of a station.",
        .long_description =
        \\Print the X register of a station. The station X register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &clientStationX,
    });
    errdefer command.registry.orderedRemove("PRINT_X");
    try command.registry.put(.{
        .name = "PRINT_Y",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Print the Y register of a station.",
        .long_description =
        \\Print the Y register of a station. The station Y register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &clientStationY,
    });
    errdefer command.registry.orderedRemove("PRINT_Y");
    try command.registry.put(.{
        .name = "PRINT_WR",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Print the Wr register of a station.",
        .long_description =
        \\Print the Wr register of a station. The station Wr register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &clientStationWr,
    });
    errdefer command.registry.orderedRemove("PRINT_WR");
    try command.registry.put(.{
        .name = "PRINT_WW",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Print the Ww register of a station.",
        .long_description =
        \\Print the Ww register of a station. The station Ww register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &clientStationWw,
    });
    errdefer command.registry.orderedRemove("PRINT_WW");
    try command.registry.put(.{
        .name = "AXIS_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Display carrier on given axis, if exists.",
        .long_description =
        \\If a carrier is recognized on the provided axis, print its carrier ID.
        ,
        .execute = &clientAxisCarrier,
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
        .execute = &clientAssertLocation,
    });
    try command.registry.put(.{
        .name = "CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Display a carrier's location.",
        .long_description =
        \\Print a given carrier's location if it is currently recognized in the
        \\provided line.
        ,
        .execute = &clientCarrierLocation,
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
        \\provided line.
        ,
        .execute = &clientCarrierAxis,
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
        .execute = &clientHallStatus,
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
        .execute = &clientAssertHall,
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
        .execute = &clientClearErrors,
    });
    errdefer command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(.{
        .name = "RESET_MCL",
        .short_description = "Reset all MCL registers.",
        .long_description =
        \\Reset all write registers (Y and Ww) on the server.
        ,
        .execute = &clientMclReset,
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
        .execute = &clientClearCarrierInfo,
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
        \\Release the servo of a given axis, allowing for free carrier movement.
        \\This command should be run before carriers move within or exit from
        \\the system due to external influence.
        ,
        .execute = &clientAxisReleaseServo,
    });
    errdefer command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put(.{
        .name = "AUTO_INITIALIZE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Initialize all carriers automatically.",
        .long_description =
        \\Isolate all carriers detected in the system automatically and move the
        \\carrier to a free space. Ignore the already initialized carrier. Upon
        \\completion, all carrier IDs will be printed and its current location.
        ,
        .execute = &clientAutoInitialize,
    });
    errdefer command.registry.orderedRemove("AUTO_INITIALIZE");
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
        .execute = &clientCalibrate,
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
        .execute = &clientSetLineZero,
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
        \\Slowly move an uninitialized carrier to separate it from other nearby
        \\carriers. A direction of "backward" or "forward" must be provided. A
        \\carrier ID can be optionally specified to give the isolated carrier an
        \\ID other than the default temporary ID 255, and the next or previous
        \\can also be linked for isolation movement. Linked axis parameter
        \\values must be one of "prev", "next", "left", or "right".
        ,
        .execute = &clientIsolate,
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
        .execute = &clientWaitIsolate,
    });
    errdefer command.registry.orderedRemove("WAIT_ISOLATE");
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
        .execute = &clientWaitMoveCarrier,
    });
    errdefer command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put(.{
        .name = "MOVE_CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system.
        ,
        .execute = &clientCarrierPosMoveAxis,
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
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number.
        ,
        .execute = &clientCarrierPosMoveLocation,
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
        .execute = &clientCarrierPosMoveDistance,
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
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system. This command moves the
        \\carrier with speed profile feedback.
        ,
        .execute = &clientCarrierSpdMoveAxis,
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
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. This command
        \\moves the carrier with speed profile feedback.
        ,
        .execute = &clientCarrierSpdMoveLocation,
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
        .execute = &clientCarrierSpdMoveDistance,
    });
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_DISTANCE");
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
        .execute = &clientCarrierPushForward,
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
        .execute = &clientCarrierPushBackward,
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
        .execute = &clientCarrierPullForward,
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
        .execute = &clientCarrierPullBackward,
    });
    errdefer command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
    try command.registry.put(.{
        .name = "WAIT_PULL_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait for carrier pull to complete.",
        .long_description =
        \\Pause the execution of any further commands until active carrier
        \\pull of the provided carrier is indicated as complete. If a timeout is
        \\specified, the command will return an error if the waiting action
        \\takes longer than the specified timeout duration. The timeout must be
        \\provided in milliseconds.
        ,
        .execute = &clientCarrierWaitPull,
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
        .execute = &clientCarrierStopPull,
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
        .execute = &clientCarrierStopPush,
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
        .execute = &clientWaitAxisEmpty,
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
    disconnect() catch {};
    arena.deinit();
    network.deinit();
}

fn serverVersion(_: [][]const u8) !void {
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_version = .{},
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const ServerVersion = protobuf_msg.ServerVersion;
        const response: ServerVersion = try ServerVersion.decode(
            msg,
            fba_allocator,
        );
        defer response.deinit();
        std.log.info("MMC Server Version: {d}.{d}.{d}\n", .{
            response.major,
            response.minor,
            response.patch,
        });
    } else {
        return error.NotConnected;
    }
}

fn clientConnect(params: [][]const u8) !void {
    std.log.debug("{}", .{params.len});
    if (main_socket) |socket| {
        if (isSocketEventOccured(
            socket,
            std.posix.POLL.IN | std.posix.POLL.OUT,
            0,
        )) |socket_status| {
            if (socket_status)
                return error.ConnectionIsAlreadyEstablished
            else
                try disconnect();
        } else |e| {
            std.log.err("{s}", .{@errorName(e)});
            try disconnect();
        }
    }
    if (params[0].len != 0 and params[1].len == 0) return error.MissingParameter;
    if (params[1].len > 0) {
        port = try std.fmt.parseInt(u16, params[0], 0);
        IP_address = @constCast(params[1]);
    }
    std.log.info(
        "Trying to connect to {s}:{}",
        .{ IP_address, port },
    );
    main_socket = try network.connectToHost(
        allocator,
        IP_address,
        port,
        .tcp,
    );
    if (main_socket) |s| {
        std.log.info(
            "Connected to {}",
            .{try s.getRemoteEndPoint()},
        );
        std.log.info("Receiving line information...", .{});
        const msg = try receive(s);
        const LineConfig = protobuf_msg.LineConfig;
        const response: LineConfig = try LineConfig.decode(
            msg,
            fba_allocator,
        );
        defer response.deinit();
        if (response.line_names.items.len != response.lines.items.len)
            return error.ConfigLineNumberOfLineNamesDoesNotMatch;
        const line_numbers = response.line_names.items.len;
        line_names = try allocator.alloc([]u8, line_numbers);
        var lines = try allocator.alloc(
            mcl.Config.Line,
            line_numbers,
        );
        defer allocator.free(lines);
        for (
            response.lines.items,
            response.line_names.items,
            0..,
        ) |line, line_name, idx| {
            line_names[idx] = try allocator.alloc(u8, line_name.getSlice().len);
            @memcpy(line_names[idx], line_name.getSlice());
            lines[idx].axes = @intCast(line.axes);
            lines[idx].ranges = try allocator.alloc(
                mcl.Config.Line.Range,
                line.ranges.items.len,
            );
            for (0..line.ranges.items.len) |range_idx| {
                const range = line.ranges.items[range_idx];
                lines[idx].ranges[range_idx].channel = std.meta.stringToEnum(
                    mcl.cc_link.Channel,
                    @tagName(range.channel),
                ).?;
                lines[idx].ranges[range_idx].end = @intCast(range.end);
                lines[idx].ranges[range_idx].start = @intCast(range.start);
            }
        }
        for (
            line_names,
            lines,
        ) |line_name, line| {
            std.log.debug("line name: {s}", .{line_name});
            std.log.debug("axes: {}", .{line.axes});
            for (line.ranges) |range| {
                std.log.debug(
                    "channel: {s}, start: {}, end: {}",
                    .{ @tagName(range.channel), range.start, range.end },
                );
            }
        }
        try mcl.Config.validate(.{ .lines = lines });
        try mcl.init(allocator, .{ .lines = lines });
        line_speeds = try allocator.alloc(u5, line_numbers);
        line_accelerations = try allocator.alloc(u8, line_numbers);
        log_lines = try allocator.alloc(LogLine, lines.len);
        for (0..line_numbers) |i| {
            log_lines[i].stations = .{false} ** 256;
            log_lines[i].status = false;
            line_speeds[i] = 12;
            line_accelerations[i] = 78;
            std.log.debug(
                "line: {s}, #axis: {}, range info: {s}:{}:{}",
                .{
                    line_names[i],
                    lines[i].axes,
                    @tagName(lines[i].ranges[0].channel),
                    lines[i].ranges[0].start,
                    lines[i].ranges[0].end,
                },
            );
            defer allocator.free(lines[i].ranges);
        }

        std.log.info(
            "Received the line configuration for the following line:",
            .{},
        );
        const stdout = std.io.getStdOut().writer();
        for (line_names) |line_name| {
            try stdout.writeByte('\t');
            try stdout.writeAll(line_name);
            try stdout.writeByte('\n');
        }
    } else {
        std.log.err("Failed to connect to server", .{});
    }
}

fn disconnect() !void {
    if (main_socket) |s| {
        std.log.info(
            "Disconnecting from server {}",
            .{try s.getRemoteEndPoint()},
        );
        s.close();
        for (line_names) |name| {
            allocator.free(name);
        }
        allocator.free(line_names);
        allocator.free(line_accelerations);
        allocator.free(line_speeds);
        allocator.free(log_lines);
        main_socket = null;
        line_names = undefined;
        line_accelerations = undefined;
        line_speeds = undefined;
        log_lines = undefined;
    } else return error.ServerNotConnected;
}

/// Serve as a callback of a `DISCONNECT` command, requires parameter.
fn clientDisconnect(_: [][]const u8) !void {
    try disconnect();
}

fn clientAutoInitialize(params: [][]const u8) !void {
    var line_id: usize = 0;
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        line_id = try matchLine(line_names, line_name) + 1;
    }
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .auto_initialize = .{
                    .line_id = if (line_id != 0)
                        @intCast(line_id)
                    else
                        null,
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
    } else return error.ServerNotConnected;
}

fn clientSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 3.0) return error.InvalidSpeed;

    const line_idx: usize = try matchLine(line_names, line_name);
    line_speeds[line_idx] = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(line_speeds[line_idx])) / 10.0,
    });
}

fn clientSetAcceleration(params: [][]const u8) !void {
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

fn clientGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    std.log.info(
        "Line {s} speed: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(line_speeds[line_idx])) / 10.0,
        },
    );
}

fn clientGetAcceleration(params: [][]const u8) !void {
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

fn getRegister(
    line_idx: mcl.Line.Index,
    axis_idx: mcl.Axis.Index.Line,
    comptime reg_type: RegisterTypeCap,
) !@field(mcl.registers, @tagName(reg_type)) {
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        comptime var _buf: [2]u8 = undefined;
        const union_field_name = "get_" ++ comptime std.ascii.lowerString(
            &_buf,
            @tagName(reg_type),
        );
        const command_kind = @unionInit(
            SendCommand.command_kind_union,
            union_field_name,
            .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_idx),
            },
        );
        command_msg.command_kind = command_kind;
        command_msg.message_type = .SEND_COMMAND;
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        return switch (reg_type) {
            .X => try parseRegisterX(msg, fba_allocator),
            .Y => try parseRegisterY(msg, fba_allocator),
            .Wr => try parseRegisterWr(msg, fba_allocator),
            .Ww => try parseRegisterWw(msg, fba_allocator),
        };
    } else return error.ServerNotConnected;
}

fn parseRegisterX(
    buffer: []const u8,
    a: std.mem.Allocator,
) !mcl.registers.X {
    const RegisterX = protobuf_msg.RegisterX;
    const response: RegisterX = try RegisterX.decode(
        buffer,
        a,
    );
    defer response.deinit();
    const x: mcl.registers.X = .{
        .cc_link_enabled = response.cc_link_enabled,
        .command_ready = response.command_ready,
        .command_received = response.command_received,
        .axis_cleared_carrier = response.axis_cleared_carrier,
        .cleared_carrier = response.cleared_carrier,
        .servo_enabled = response.servo_enabled,
        .emergency_stop_enabled = response.emergency_stop_enabled,
        .paused = response.paused,
        .motor_enabled = .{
            .axis1 = response.motor_enabled.?.axis1,
            .axis2 = response.motor_enabled.?.axis2,
            .axis3 = response.motor_enabled.?.axis3,
        },
        .vdc_overvoltage_detected = response.vdc_overvoltage_detected,
        .vdc_undervoltage_detected = response.vdc_undervoltage_detected,
        .errors_cleared = response.errors_cleared,
        .communication_error = .{
            .from_next = response.communication_error.?.from_next,
            .from_prev = response.communication_error.?.from_prev,
        },
        .inverter_overheat_detected = response.inverter_overheat_detected,
        .overcurrent_detected = .{
            .axis1 = response.overcurrent_detected.?.axis1,
            .axis2 = response.overcurrent_detected.?.axis2,
            .axis3 = response.overcurrent_detected.?.axis3,
        },
        .hall_alarm = .{
            .axis1 = .{
                .back = response.hall_alarm.?.axis1.?.back,
                .front = response.hall_alarm.?.axis1.?.front,
            },
            .axis2 = .{
                .back = response.hall_alarm.?.axis2.?.back,
                .front = response.hall_alarm.?.axis2.?.front,
            },
            .axis3 = .{
                .back = response.hall_alarm.?.axis3.?.back,
                .front = response.hall_alarm.?.axis3.?.front,
            },
        },
        .wait_pull_carrier = .{
            .axis1 = response.wait_pull_carrier.?.axis1,
            .axis2 = response.wait_pull_carrier.?.axis2,
            .axis3 = response.wait_pull_carrier.?.axis3,
        },
        .wait_push_carrier = .{
            .axis1 = response.wait_push_carrier.?.axis1,
            .axis2 = response.wait_push_carrier.?.axis2,
            .axis3 = response.wait_push_carrier.?.axis3,
        },
        .control_loop_max_time_exceeded = response.control_loop_max_time_exceeded,
        .initial_data_processing_request = response.initial_data_processing_request,
        .initial_data_setting_complete = response.initial_data_setting_complete,
        .error_status = response.error_status,
        .remote_ready = response.remote_ready,
    };
    return x;
}

test parseRegisterX {
    const x: mcl.registers.X = .{
        .cc_link_enabled = true,
        .command_ready = true,
        .command_received = false,
        .axis_cleared_carrier = false,
        .cleared_carrier = false,
        .servo_enabled = true,
        .emergency_stop_enabled = false,
        .paused = false,
        .motor_enabled = .{
            .axis1 = true,
            .axis2 = true,
            .axis3 = false,
        },
        .vdc_overvoltage_detected = false,
        .vdc_undervoltage_detected = false,
        .errors_cleared = false,
        .communication_error = .{
            .from_next = false,
            .from_prev = true,
        },
        .inverter_overheat_detected = false,
        .overcurrent_detected = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .hall_alarm = .{
            .axis1 = .{
                .back = false,
                .front = true,
            },
            .axis2 = .{
                .back = true,
                .front = false,
            },
            .axis3 = .{
                .back = false,
                .front = false,
            },
        },
        .wait_pull_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .wait_push_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .control_loop_max_time_exceeded = false,
        .initial_data_processing_request = false,
        .initial_data_setting_complete = false,
        .error_status = false,
        .remote_ready = false,
    };
    const RegisterX = protobuf_msg.RegisterX;
    var response: RegisterX = RegisterX.init(std.testing.allocator);
    response = std.mem.zeroInit(RegisterX, .{});
    defer response.deinit();
    // Copy the value of x to response
    response = .{
        .cc_link_enabled = true,
        .command_ready = true,
        .command_received = false,
        .axis_cleared_carrier = false,
        .cleared_carrier = false,
        .servo_enabled = true,
        .emergency_stop_enabled = false,
        .paused = false,
        .motor_enabled = .{
            .axis1 = true,
            .axis2 = true,
            .axis3 = false,
        },
        .vdc_overvoltage_detected = false,
        .vdc_undervoltage_detected = false,
        .errors_cleared = false,
        .communication_error = .{
            .from_next = false,
            .from_prev = true,
        },
        .inverter_overheat_detected = false,
        .overcurrent_detected = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .hall_alarm = .{
            .axis1 = .{
                .back = false,
                .front = true,
            },
            .axis2 = .{
                .back = true,
                .front = false,
            },
            .axis3 = .{
                .back = false,
                .front = false,
            },
        },
        .wait_pull_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .wait_push_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .control_loop_max_time_exceeded = false,
        .initial_data_processing_request = false,
        .initial_data_setting_complete = false,
        .error_status = false,
        .remote_ready = false,
    };
    const encoded = try response.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(
        x,
        try parseRegisterX(
            encoded,
            std.testing.allocator,
        ),
    );
}

fn clientStationX(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const x = try getRegister(
        line_idx,
        axis_idx,
        .X,
    );
    std.log.info("{}", .{x});
}

fn parseRegisterY(
    buffer: []const u8,
    a: std.mem.Allocator,
) !mcl.registers.Y {
    const RegisterY = protobuf_msg.RegisterY;
    const response: RegisterY = try RegisterY.decode(
        buffer,
        a,
    );
    defer response.deinit();
    const y: mcl.registers.Y = .{
        .cc_link_enable = response.cc_link_enable,
        .start_command = response.start_command,
        .reset_command_received = response.reset_command_received,
        .axis_clear_carrier = response.axis_clear_carrier,
        .clear_carrier = response.clear_carrier,
        .axis_servo_release = response.axis_servo_release,
        .servo_release = response.servo_release,
        .emergency_stop = response.emergency_stop,
        .temporary_pause = response.temporary_pause,
        .clear_errors = response.clear_errors,
        .reset_pull_carrier = .{
            .axis1 = response.reset_pull_carrier.?.axis1,
            .axis2 = response.reset_pull_carrier.?.axis2,
            .axis3 = response.reset_pull_carrier.?.axis3,
        },
        .reset_push_carrier = .{
            .axis1 = response.reset_push_carrier.?.axis1,
            .axis2 = response.reset_push_carrier.?.axis2,
            .axis3 = response.reset_push_carrier.?.axis3,
        },
    };
    return y;
}

test parseRegisterY {
    const y: mcl.registers.Y = .{
        .cc_link_enable = true,
        .start_command = false,
        .reset_command_received = false,
        .axis_clear_carrier = false,
        .clear_carrier = false,
        .axis_servo_release = false,
        .servo_release = false,
        .emergency_stop = false,
        .temporary_pause = false,
        .clear_errors = false,
        .reset_pull_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .reset_push_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
    };
    const RegisterY = protobuf_msg.RegisterY;
    var response: RegisterY = RegisterY.init(std.testing.allocator);
    response = std.mem.zeroInit(RegisterY, .{});
    defer response.deinit();
    // Copy the value of y to the response
    response = .{
        .cc_link_enable = true,
        .start_command = false,
        .reset_command_received = false,
        .axis_clear_carrier = false,
        .clear_carrier = false,
        .axis_servo_release = false,
        .servo_release = false,
        .emergency_stop = false,
        .temporary_pause = false,
        .clear_errors = false,
        .reset_pull_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
        .reset_push_carrier = .{
            .axis1 = false,
            .axis2 = false,
            .axis3 = false,
        },
    };
    const encoded = try response.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(
        y,
        try parseRegisterY(
            encoded,
            std.testing.allocator,
        ),
    );
}

fn clientStationY(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const y = try getRegister(
        line_idx,
        axis_idx,
        .Y,
    );
    std.log.info("{}", .{y});
}

fn parseRegisterWr(
    buffer: []const u8,
    a: std.mem.Allocator,
) !mcl.registers.Wr {
    const RegisterWr = protobuf_msg.RegisterWr;
    const response: RegisterWr = try RegisterWr.decode(
        buffer,
        a,
    );
    defer response.deinit();
    // wr.received_backward.kind type cannot be accessed within mcl library
    comptime var kind_type: type = undefined;
    inline for (@typeInfo(mcl.registers.Wr).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, "received_backward", field.name)) {
            inline for (@typeInfo(field.type).@"struct".fields) |inner_field| {
                if (comptime std.mem.eql(u8, "kind", inner_field.name)) {
                    kind_type = inner_field.type;
                    break;
                }
            }
            break;
        }
    }
    const wr: mcl.registers.Wr = .{
        .command_response = std.meta.stringToEnum(
            mcl.registers.Wr.CommandResponseCode,
            @tagName(response.command_response),
        ) orelse return error.UnknownCommandResponse,
        .received_backward = .{
            .id = @intCast(response.received_backward.?.id),
            .failed_bcc = response.received_backward.?.failed_bcc,
            .kind = std.meta.stringToEnum(
                kind_type,
                @tagName(response.received_backward.?.kind),
            ).?,
        },
        .received_forward = .{
            .id = @intCast(response.received_forward.?.id),
            .failed_bcc = response.received_forward.?.failed_bcc,
            .kind = std.meta.stringToEnum(
                kind_type,
                @tagName(response.received_forward.?.kind),
            ).?,
        },
        .carrier = .{
            .axis1 = .{
                .location = response.carrier.?.axis1.?.location,
                .id = @intCast(response.carrier.?.axis1.?.id),
                .arrived = response.carrier.?.axis1.?.arrived,
                .auxiliary = response.carrier.?.axis1.?.auxiliary,
                .enabled = response.carrier.?.axis1.?.enabled,
                .quasi = response.carrier.?.axis1.?.quasi,
                .cas = .{
                    .enabled = response.carrier.?.axis1.?.cas.?.enabled,
                    .triggered = response.carrier.?.axis1.?.cas.?.triggered,
                },
                .state = std.meta.stringToEnum(
                    mcl.registers.Wr.Carrier.State,
                    @tagName(response.carrier.?.axis1.?.state),
                ).?,
            },
            .axis2 = .{
                .location = response.carrier.?.axis2.?.location,
                .id = @intCast(response.carrier.?.axis2.?.id),
                .arrived = response.carrier.?.axis2.?.arrived,
                .auxiliary = response.carrier.?.axis2.?.auxiliary,
                .enabled = response.carrier.?.axis2.?.enabled,
                .quasi = response.carrier.?.axis2.?.quasi,
                .cas = .{
                    .enabled = response.carrier.?.axis2.?.cas.?.enabled,
                    .triggered = response.carrier.?.axis2.?.cas.?.triggered,
                },
                .state = std.meta.stringToEnum(
                    mcl.registers.Wr.Carrier.State,
                    @tagName(response.carrier.?.axis2.?.state),
                ).?,
            },
            .axis3 = .{
                .location = response.carrier.?.axis3.?.location,
                .id = @intCast(response.carrier.?.axis3.?.id),
                .arrived = response.carrier.?.axis3.?.arrived,
                .auxiliary = response.carrier.?.axis3.?.auxiliary,
                .enabled = response.carrier.?.axis3.?.enabled,
                .quasi = response.carrier.?.axis3.?.quasi,
                .cas = .{
                    .enabled = response.carrier.?.axis3.?.cas.?.enabled,
                    .triggered = response.carrier.?.axis3.?.cas.?.triggered,
                },
                .state = std.meta.stringToEnum(
                    mcl.registers.Wr.Carrier.State,
                    @tagName(response.carrier.?.axis3.?.state),
                ).?,
            },
        },
    };
    return wr;
}

// This test cannot run at all. It is stuck in defining wr variable.
// However, the usage of parseRegisterWr written in this test is correct.
test parseRegisterWr {
    // const wr: mcl.registers.Wr = .{
    //     .command_response = .CarrierAlreadyExists,
    //     ._16 = 0,
    //     .received_backward = .{
    //         .id = 1,
    //         .failed_bcc = false,
    //         .kind = .off_pos_req,
    //     },
    //     .received_forward = .{
    //         .id = 2,
    //         .failed_bcc = false,
    //         .kind = .prof_noti,
    //     },
    //     .carrier = .{
    //         .axis1 = .{
    //             .location = 0.0,
    //             .id = 0,
    //             .arrived = false,
    //             .auxiliary = false,
    //             .enabled = false,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = false,
    //                 .triggered = false,
    //             },
    //             .state = .None,
    //             ._42 = 0,
    //             ._54 = 0,
    //         },
    //         .axis2 = .{
    //             .location = 330.0,
    //             .id = 1,
    //             .arrived = true,
    //             .auxiliary = false,
    //             .enabled = true,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = true,
    //                 .triggered = false,
    //             },
    //             .state = .PosMoveCompleted,
    //             ._42 = 0,
    //             ._54 = 0,
    //         },
    //         .axis3 = .{
    //             .location = 0.0,
    //             .id = 0,
    //             .arrived = false,
    //             .auxiliary = false,
    //             .enabled = false,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = false,
    //                 .triggered = false,
    //             },
    //             .state = .None,
    //             ._42 = 0,
    //             ._54 = 0,
    //         },
    //     },
    // };
    // const RegisterWr = protobuf_msg.RegisterWr;
    // var response: RegisterWr = RegisterWr.init(std.testing.allocator);
    // response = std.mem.zeroInit(RegisterWr, .{});
    // defer response.deinit();
    // // Copy the value of wr to the response
    // response = .{
    //     .command_response = .CarrierAlreadyExists,
    //     .received_backward = .{
    //         .id = 1,
    //         .failed_bcc = false,
    //         .kind = .off_pos_req,
    //     },
    //     .received_forward = .{
    //         .id = 2,
    //         .failed_bcc = false,
    //         .kind = .prof_noti,
    //     },
    //     .carrier = .{
    //         .axis1 = .{
    //             .location = 0,
    //             .id = 0,
    //             .arrived = false,
    //             .auxiliary = false,
    //             .enabled = false,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = false,
    //                 .triggered = false,
    //             },
    //             .state = .None,
    //         },
    //         .axis2 = .{
    //             .location = 330,
    //             .id = 1,
    //             .arrived = true,
    //             .auxiliary = false,
    //             .enabled = true,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = true,
    //                 .triggered = false,
    //             },
    //             .state = .PosMoveCompleted,
    //         },
    //         .axis3 = .{
    //             .location = 0,
    //             .id = 0,
    //             .arrived = false,
    //             .auxiliary = false,
    //             .enabled = false,
    //             .quasi = false,
    //             .cas = .{
    //                 .enabled = false,
    //                 .triggered = false,
    //             },
    //             .state = .None,
    //         },
    //     },
    // };
    // const encoded = try response.encode(std.testing.allocator);
    // defer std.testing.allocator.free(encoded);
    // try std.testing.expectEqual(
    //     wr,
    //     try parseRegisterWr(
    //         encoded,
    //         std.testing.allocator,
    //     ),
    // );
}

fn clientStationWr(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const wr = try getRegister(
        line_idx,
        axis_idx,
        .Wr,
    );
    std.log.info("{}", .{wr});
}

fn parseRegisterWw(
    buffer: []const u8,
    a: std.mem.Allocator,
) !mcl.registers.Ww {
    const RegisterWw = protobuf_msg.RegisterWw;
    const response: RegisterWw = try RegisterWw.decode(
        buffer,
        a,
    );
    defer response.deinit();
    const ww: mcl.registers.Ww = .{
        .command = std.meta.stringToEnum(
            mcl.registers.Ww.Command,
            @tagName(response.command),
        ).?,
        .axis = @intCast(response.axis),
        .carrier = .{
            .id = @intCast(response.carrier.?.id),
            .enable_cas = response.carrier.?.enable_cas,
            .isolate_link_next_axis = response.carrier.?.isolate_link_next_axis,
            .isolate_link_prev_axis = response.carrier.?.isolate_link_prev_axis,
            .speed = @intCast(response.carrier.?.speed),
            .acceleration = @intCast(response.carrier.?.acceleration),
            .target = switch (response.command) {
                .SPEED_MOVE_CARRIER_AXIS,
                .POSITION_MOVE_CARRIER_AXIS,
                => .{ .u32 = @intCast(response.carrier.?.target.?.u32) },
                .SPEED_MOVE_CARRIER_DISTANCE,
                .SPEED_MOVE_CARRIER_LOCATION,
                .POSITION_MOVE_CARRIER_DISTANCE,
                .POSITION_MOVE_CARRIER_LOCATION,
                .PULL_TRANSITION_LOCATION_BACKWARD,
                .PULL_TRANSITION_LOCATION_FORWARD,
                => .{ .f32 = response.carrier.?.target.?.f32 },
                else => .{ .u32 = 0 },
            },
        },
    };
    return ww;
}

// This test cannot be run as Ww have a packed union (untagged union). Zig
// cannot compare untagged union. However, the usage of parseRegisterWr written
// in this test is correct.
test parseRegisterWw {
    // const ww: mcl.registers.Ww = .{
    //     .command = .PositionMoveCarrierAxis,
    //     .axis = 0,
    //     .carrier = .{
    //         .id = 1,
    //         .enable_cas = true,
    //         .isolate_link_next_axis = false,
    //         .isolate_link_prev_axis = false,
    //         .speed = 12,
    //         .acceleration = 78,
    //         .target = .{
    //             .u32 = 2,
    //         },
    //     },
    // };
    // inline for (@typeInfo(@TypeOf(ww)).@"struct".fields) |field| {
    //     @compileLog(field.name, field.type);
    // }

    // const RegisterWw = protobuf_msg.RegisterWw;
    // var response: RegisterWw = RegisterWw.init(std.testing.allocator);
    // response = std.mem.zeroInit(RegisterWw, .{});
    // defer response.deinit();
    // // Copy the value of wr to the response
    // response = .{
    //     .command = .PositionMoveCarrierAxis,
    //     .axis = 0,
    //     .carrier = .{
    //         .id = 1,
    //         .enable_cas = true,
    //         .isolate_link_next_axis = false,
    //         .isolate_link_prev_axis = false,
    //         .speed = 12,
    //         .acceleration = 78,
    //         .target = .{ .u32 = 2 },
    //     },
    // };
    // const encoded = try response.encode(std.testing.allocator);
    // defer std.testing.allocator.free(encoded);
    // try std.testing.expectEqual(
    //     ww,
    //     try parseRegisterWw(
    //         encoded,
    //         std.testing.allocator,
    //     ),
    // );
}

fn clientStationWw(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const ww = try getRegister(
        line_idx,
        axis_idx,
        .Ww,
    );
    std.log.info("{}", .{ww});
}

fn clientAxisCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_carrier_status = .{
                    .line_idx = @intCast(line_idx),
                    .param = .{
                        .axis_idx = @intCast(axis_idx),
                    },
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
        defer carrier.deinit();
        if (carrier.id == 0) {
            std.log.info(
                "No carrier recognized on axis {d}.\n",
                .{axis_id},
            );
        } else {
            std.log.info(
                "Carrier {d} on axis {d}.\n",
                .{ carrier.id, axis_id },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientAssertLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const expected_location: f32 = try std.fmt.parseFloat(f32, params[2]);
    // Default location threshold value is 1 mm
    const location_thr = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        1.0;
    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        // Get carrier status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_carrier_status = .{
                    .line_idx = @intCast(line_idx),
                    .param = .{
                        .carrier_id = @intCast(carrier_id),
                    },
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
        defer carrier.deinit();
        const location: f32 = carrier.location;
        if (location < expected_location - location_thr or
            location > expected_location + location_thr)
            return error.UnexpectedCarrierLocation;
    } else return error.ServerNotConnected;
}

fn clientAxisReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .release_axis_servo = .{
                    .line_idx = @intCast(line_idx),
                    .axis_idx = @intCast(axis_idx),
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
    } else return error.ServerNotConnected;
}

fn clientClearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: mcl.Line.Index = @intCast(try matchLine(line_names, line_name));
    const line = mcl.lines[line_idx];

    var axis_id: ?mcl.Axis.Id.Line = null;
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id.? < 1 or axis_id.? > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const axis_idx: ?mcl.Axis.Index.Line = if (axis_id) |id|
        @intCast(id - 1)
    else
        null;
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_kind = .{
            .clear_errors = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = if (axis_idx) |idx|
                    @intCast(idx)
                else
                    null,
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientClearCarrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: mcl.Line.Index = @intCast(try matchLine(line_names, line_name));
    const line = mcl.lines[line_idx];

    var axis_id: ?mcl.Axis.Id.Line = null;
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id.? < 1 or axis_id.? > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const axis_idx: ?mcl.Axis.Index.Line = if (axis_id) |id|
        @intCast(id - 1)
    else
        null;
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_kind = .{
            .clear_carrier_info = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = if (axis_idx) |idx|
                    @intCast(idx)
                else
                    null,
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        // Get carrier status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_carrier_status = .{
                    .line_idx = @intCast(line_idx),
                    .param = .{
                        .carrier_id = @intCast(carrier_id),
                    },
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);

        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
        defer carrier.deinit();
        if (carrier.id == 0) {
            std.log.err(
                "Carrier not found",
                .{},
            );
        } else {
            std.log.info(
                "Carrier {d} location: {d} mm",
                .{ carrier.id, carrier.location },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    if (main_socket) |s| {
        // Get carrier status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_carrier_status = .{
                    .line_idx = @intCast(line_idx),
                    .param = .{
                        .carrier_id = @intCast(carrier_id),
                    },
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);

        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
        defer carrier.deinit();
        if (carrier.id == 0) {
            std.log.err(
                "Carrier not found",
                .{},
            );
        } else {
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, carrier.main_axis + 1 },
            );
            if (carrier.aux_axis == 0) return;
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, carrier.aux_axis + 1 },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientHallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    var axis_id: ?mcl.Axis.Id.Line = null;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id.? < 1 or axis_id.? > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const axis_idx: ?mcl.Axis.Index.Line = if (axis_id != null)
        @intCast(axis_id.? - 1)
    else
        axis_id;

    if (main_socket) |s| {
        if (axis_idx) |idx| {
            // Get hall sensor status from the server

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();

            command_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_hall_status = .{
                        .line_idx = @intCast(line_idx),
                        .axis_idx = @intCast(idx),
                    },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);

            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const hall: HallStatus = try HallStatus.decode(msg, fba_allocator);
            defer hall.deinit();
            std.log.info(
                "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                .{
                    axis_id.?,
                    if (hall.front) "ON" else "OFF",
                    if (hall.back) "ON" else "OFF",
                },
            );
            return;
        }

        for (line.axes) |axis| {
            // Get carrier status from the server

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();
            command_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_hall_status = .{
                        .line_idx = @intCast(line_idx),
                        .axis_idx = @intCast(axis.index.line),
                    },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);
            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const hall: HallStatus = try HallStatus.decode(msg, fba_allocator);
            defer hall.deinit();
            std.log.info(
                "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                .{
                    axis.id.line,
                    if (hall.front) "ON" else "OFF",
                    if (hall.back) "ON" else "OFF",
                },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientAssertHall(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(
        mcl.Axis.Id.Line,
        params[1],
        0,
    );
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
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var alarm_on: bool = true;
    if (params[3].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[3])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[3])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }

    if (main_socket) |s| {
        // Get hall status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .get_hall_status = .{
                    .line_idx = @intCast(line_idx),
                    .axis_idx = @intCast(axis_idx),
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);

        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s);
        const hall: HallStatus = try HallStatus.decode(msg, fba_allocator);
        defer hall.deinit();
        switch (side) {
            .backward => {
                if (hall.back != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
            .forward => {
                if (hall.front != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
        }
    } else return error.ServerNotConnected;
}

fn clientMclReset(_: [][]const u8) !void {
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_kind = .{
            .reset_mcl = .{},
        },
    };
    const encoded = try command_msg.encode(fba_allocator);
    defer fba_allocator.free(encoded);
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .CALIBRATION,
        .command_kind = .{
            .calibrate = .{
                .line_idx = @intCast(line_idx),
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientSetLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .SET_LINE_ZERO,
        .command_kind = .{
            .set_line_zero = .{
                .line_idx = @intCast(line_idx),
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(u16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const dir: Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .FORWARD;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .BACKWARD;
        } else {
            return error.InvalidDirection;
        }
    };

    const carrier_id: u10 = if (params[3].len > 0)
        try std.fmt.parseInt(u10, params[3], 0)
    else
        0;
    const link_axis: Direction = link: {
        if (params[4].len > 0) {
            if (std.ascii.eqlIgnoreCase("next", params[4]) or
                std.ascii.eqlIgnoreCase("right", params[4]))
            {
                break :link .FORWARD;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .BACKWARD;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link .DIRECTION_UNSPECIFIED;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = if (dir == .FORWARD)
            .ISOLATE_FORWARD
        else
            .ISOLATE_BACKWARD,
        .command_kind = .{
            .isolate_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
                .carrier_id = carrier_id,
                .link_axis = link_axis,
                .direction = dir,
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientWaitIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        var wait_timer = try std.time.Timer.start();
        while (true) {
            if (timeout != 0 and
                wait_timer.read() > timeout * std.time.ns_per_ms)
                return error.WaitTimeout;
            try command.checkCommandInterrupt();

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();

            command_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_carrier_status = .{
                        .line_idx = @intCast(line_idx),
                        .param = .{
                            .carrier_id = @intCast(carrier_id),
                        },
                    },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);

            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
            defer carrier.deinit();
            std.log.debug(
                "line: {s}, carrier id: {}, carrier state: {s}",
                .{ line_name, carrier.id, @tagName(carrier.state) },
            );
            if (carrier.state == .BACKWARD_ISOLATION_COMPLETED or
                carrier.state == .FORWARD_ISOLATION_COMPLETED) return;
        }
    } else return error.ServerNotConnected;
}

fn clientWaitMoveCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        var wait_timer = try std.time.Timer.start();
        while (true) {
            if (timeout != 0 and
                wait_timer.read() > timeout * std.time.ns_per_ms)
                return error.WaitTimeout;
            try command.checkCommandInterrupt();

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();

            command_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_carrier_status = .{
                        .line_idx = @intCast(line_idx),
                        .param = .{
                            .carrier_id = @intCast(carrier_id),
                        },
                    },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);

            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const carrier: CarrierStatus = try CarrierStatus.decode(msg, fba_allocator);
            defer carrier.deinit();
            std.log.debug(
                "line: {s}, carrier id: {}, carrier state: {s}",
                .{ line_name, carrier.id, @tagName(carrier.state) },
            );
            if (carrier.state == .POS_MOVE_COMPLETED or
                carrier.state == .SPD_MOVE_COMPLETED) return;
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .POSITION_MOVE_CARRIER_AXIS,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .axis_id = @intCast(axis_id) },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .POSITION_MOVE_CARRIER_LOCATION,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .location_distance = location },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .POSITION_MOVE_CARRIER_DISTANCE,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .location_distance = distance },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .SPEED_MOVE_CARRIER_AXIS,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .axis_id = @intCast(axis_id) },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .SPEED_MOVE_CARRIER_LOCATION,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .location_distance = location },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx: usize = try matchLine(line_names, line_name);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = .SPEED_MOVE_CARRIER_DISTANCE,
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .target = .{ .location_distance = distance },
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?mcl.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(mcl.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_code: protobuf_msg.RegisterWw.CommandCode = undefined;
    var command_axis: ?i32 = null;
    if (axis_id) |id| {
        const line = mcl.lines[line_idx];
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        const axis: mcl.Axis = line.axes[id - 1];
        command_code = .PUSH_TRANSITION_FORWARD;
        command_axis = @intCast(axis.index.line);
    } else {
        command_code = .PUSH_FORWARD;
    }
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = command_code,
        .command_kind = .{
            .push_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .direction = .FORWARD,
                .axis_idx = command_axis,
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?mcl.Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(mcl.Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx: usize = try matchLine(line_names, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_code: protobuf_msg.RegisterWw.CommandCode = undefined;
    var command_axis: ?i32 = null;
    if (axis_id) |id| {
        const line = mcl.lines[line_idx];
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        const axis: mcl.Axis = line.axes[id - 1];
        command_code = .PUSH_TRANSITION_BACKWARD;
        command_axis = @intCast(axis.index.line);
    } else {
        command_code = .PUSH_BACKWARD;
    }
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = command_code,
        .command_kind = .{
            .push_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .direction = .BACKWARD,
                .axis_idx = command_axis,
            },
        },
    };

    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_code: protobuf_msg.RegisterWw.CommandCode = undefined;
    var command_destination: ?f32 = null;
    if (destination) |dest| {
        command_code = .PULL_TRANSITION_LOCATION_FORWARD;
        command_destination = dest;
    } else {
        command_code = .PULL_FORWARD;
    }
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = command_code,
        .command_kind = .{
            .pull_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .direction = .FORWARD,
                .destination = command_destination,
            },
        },
    };

    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_code: protobuf_msg.RegisterWw.CommandCode = undefined;
    var command_destination: ?f32 = null;
    if (destination) |dest| {
        command_code = .PULL_TRANSITION_LOCATION_BACKWARD;
        command_destination = dest;
    } else {
        command_code = .PULL_BACKWARD;
    }
    command_msg = .{
        .message_type = .SEND_COMMAND,
        .command_code = command_code,
        .command_kind = .{
            .pull_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
                .carrier_id = carrier_id,
                .speed = @intCast(line_speeds[line_idx]),
                .acceleration = @intCast(line_accelerations[line_idx]),
                .direction = .BACKWARD,
                .destination = command_destination,
            },
        },
    };
    try sendMessageAndWaitReceived(
        command_msg,
    );
}

fn clientCarrierWaitPull(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        var wait_timer = try std.time.Timer.start();
        while (true) {
            if (timeout != 0 and
                wait_timer.read() > timeout * std.time.ns_per_ms)
                return error.WaitTimeout;
            try command.checkCommandInterrupt();

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();

            command_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_carrier_status = .{
                        .line_idx = @intCast(line_idx),
                        .param = .{
                            .carrier_id = @intCast(carrier_id),
                        },
                    },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);

            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const carrier: CarrierStatus =
                try CarrierStatus.decode(msg, fba_allocator);
            defer carrier.deinit();
            if (carrier.state == .PULL_FORWARD_COMPLETED or
                carrier.state == .PULL_BACKWARD_COMPLETED) return;
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .stop_pull_carrier = .{
                    .line_idx = @intCast(line_idx),
                    .axis_idx = @intCast(axis_index),
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);

        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
    } else return error.ServerNotConnected;
}

fn clientCarrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
            .message_type = .SEND_COMMAND,
            .command_kind = .{
                .stop_push_carrier = .{
                    .line_idx = @intCast(line_idx),
                    .axis_idx = @intCast(axis_index),
                },
            },
        };
        const encoded = try command_msg.encode(fba_allocator);
        defer fba_allocator.free(encoded);

        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
    } else return error.ServerNotConnected;
}

fn clientWaitAxisEmpty(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx: mcl.Line.Index = @intCast(try matchLine(
        line_names,
        line_name,
    ));
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis: mcl.Axis = line.axes[axis_id - 1];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        const wr = try getRegister(
            line_idx,
            axis.index.line,
            .Wr,
        );
        const x = try getRegister(
            line_idx,
            axis.index.line,
            .X,
        );
        const carrier = wr.carrier.axis(axis.index.station);
        const axis_alarms = x.hall_alarm.axis(axis.index.station);
        if (carrier.id == 0 and !axis_alarms.back and !axis_alarms.front and
            !axis.station.x.wait_pull_carrier.axis(axis.index.station) and
            !axis.station.x.wait_push_carrier.axis(axis.index.station))
        {
            break;
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
        const station_index: mcl.Station.Index = @intCast(axis_index / 3);
        log.stations[station_index] = true;
    }

    // Validate "registers" parameter
    var reg_input_iterator = std.mem.tokenizeSequence(u8, params[2], ",");
    outer: while (reg_input_iterator.next()) |token| {
        if (std.ascii.eqlIgnoreCase("all", token)) {
            inline for (@typeInfo(RegisterType).@"enum".fields) |field| {
                log.registers.set(@enumFromInt(field.value), true);
            }
            break;
        }
        inline for (@typeInfo(RegisterType).@"enum".fields) |field| {
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
    defer log_file.close();

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
        logging_data.writeItemOverwrite(logRegisters(
            log_time_start,
            &timer,
        ) catch {
            std.log.info("saving logging data..", .{});
            break;
        });
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
        const line_idx: mcl.Line.Index = @intCast(try matchLine(
            line_names,
            line_name,
        ));
        if (log_lines[line_idx].status == false) continue;
        const line = mcl.lines[line_idx];
        for (line.stations) |station| {
            const station_idx = station.index;
            const axis_idx = station.axes[0].index.line;
            if (log_lines[line_idx].stations[station_idx] == false) continue;
            // const station = line.stations[station_idx];
            var reg_iterator = log_lines[line_idx].registers.iterator();
            while (reg_iterator.next()) |reg_entry| {
                const reg_type = @TypeOf(reg_entry.key);
                inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                    if (@intFromEnum(reg_entry.key) == reg_enum.value and
                        reg_entry.value.* == true)
                    {
                        switch (reg_entry.key) {
                            .x => {
                                const x = try getRegister(
                                    line_idx,
                                    axis_idx,
                                    .X,
                                );
                                result.registers[reg_idx].x = x;
                            },
                            .y => {
                                const y = try getRegister(
                                    line_idx,
                                    axis_idx,
                                    .Y,
                                );
                                result.registers[reg_idx].y = y;
                            },
                            .wr => {
                                const wr = try getRegister(
                                    line_idx,
                                    axis_idx,
                                    .Wr,
                                );
                                result.registers[reg_idx].wr = wr;
                            },
                            .ww => {
                                const ww = try getRegister(
                                    line_idx,
                                    axis_idx,
                                    .Ww,
                                );
                                result.registers[reg_idx].ww = ww;
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

fn sendMessageAndWaitReceived(
    command_msg: SendCommand,
) !void {
    if (main_socket) |s| {
        var command_id: i32 = undefined;
        {
            // Send command and wait for its response
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);
            std.log.debug(
                "message: {s}",
                .{@tagName(command_msg.command_kind.?)},
            );
            try send(s, encoded);
            const msg = try receive(s);
            const CommandID = protobuf_msg.CommandID;
            const response: CommandID = try CommandID.decode(msg, fba_allocator);
            defer response.deinit();
            command_id = response.command_id;
        }
        while (true) {
            try command.checkCommandInterrupt();
            var command_status_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_status_msg.deinit();
            command_status_msg = .{
                .message_type = .SEND_COMMAND,
                .command_kind = .{
                    .get_command_status = .{ .command_id = command_id },
                },
            };
            const encoded = try command_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);
            try send(s, encoded);
            const msg = try receive(s);
            const CommandStatus = protobuf_msg.CommandStatus;
            const response: CommandStatus = try CommandStatus.decode(msg, fba_allocator);
            defer response.deinit();
            switch (response.status) {
                .PROGRESSING => {}, // continue the loop
                .COMPLETED => break,
                .FAILED => {
                    if (response.error_response) |err| {
                        return switch (err) {
                            .CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                            .VDC_UNDERVOLTAGE_DETECTED => error.VDCUndervoltageDetected,
                            .VDC_OVERVOLTAGE_DETECTED => error.VDCOvervoltageDetected,
                            .COMMUNICATION_ERROR_DETECTED => error.CommunicationErrorDetected,
                            .INVERTER_OVERHEAT_DETECTED => error.InverterOverheatDetected,
                            .OVERCURRENT_DETECTED => error.OvercurrentDetected,
                            .CONTROL_LOOP_MAX_TIME_EXCEEDED => error.ControlLoopMaxTimeExceeded,
                            .INVALID_COMMAND => error.InvalidCommmand,
                            .CARRIER_NOT_FOUND => error.CarrierNotFound,
                            .HOMING_FAILED => error.HomingFailed,
                            .INVALID_PARAMETER => error.InvalidParameter,
                            .INVALID_SYSTEM_STATE => error.InvalidSystemState,
                            .CARRIER_ALREADY_EXISTS => error.CarrierAlreadyExists,
                            .INVALID_AXIS => error.InvalidAxis,
                            else => error.UnexpectedResponse,
                        };
                    } else return error.UnexpectedResponse;
                },
                else => return error.UnexpectedResponse,
            }
        }
    } else return error.ServerNotConnected;
}

// fn parseCarrierStatus(
//     buffer: []const u8,
//     a: std.mem.Allocator,
// ) !protobuf_msg.CarrierStatus {
//     const CarrierStatus = protobuf_msg.CarrierStatus;
//     const response: CarrierStatus = try CarrierStatus.decode(
//         buffer,
//         a,
//     );
//     defer response.deinit();
//     return response.decode(input: []const u8, allocator: Allocator)
//     // TODO: Find out why state_type != mcl.registers.Wr.Carrier.State
//     comptime var state_type: type = undefined;
//     inline for (@typeInfo(SystemState.Carrier).@"struct".fields) |field| {
//         if (comptime std.mem.eql(u8, "state", field.name)) {
//             state_type = field.type;
//             break;
//         }
//     }
//     const carrier: SystemState.Carrier = .{
//         .axis_idx = .{
//             .aux_axis = @intCast(response.axis_idx.?.aux_axis),
//             .main_axis = @intCast(response.axis_idx.?.main_axis),
//         },
//         .id = @intCast(response.id),
//         .location = response.location,
//         .state = std.meta.stringToEnum(
//             state_type,
//             @tagName(response.state),
//         ).?,
//     };
//     return carrier;
// }

// test parseCarrierStatus {
//     const carrier: SystemState.Carrier = .{
//         .axis_idx = .{
//             .aux_axis = 1,
//             .main_axis = 2,
//         },
//         .id = 1,
//         .location = 0.0,
//         .state = .PosMoveCompleted,
//     };
//     const CarrierStatus = protobuf_msg.CarrierStatus;
//     var response: CarrierStatus = CarrierStatus.init(std.testing.allocator);
//     response = std.mem.zeroInit(CarrierStatus, .{});
//     defer response.deinit();
//     // Copy the value of y to the response
//     response = .{
//         .axis_idx = .{
//             .aux_axis = 1,
//             .main_axis = 2,
//         },
//         .id = 1,
//         .location = 0.0,
//         .state = .PosMoveCompleted,
//     };
//     const encoded = try response.encode(std.testing.allocator);
//     defer std.testing.allocator.free(encoded);
//     try std.testing.expectEqual(
//         carrier,
//         try parseCarrierStatus(
//             encoded,
//             std.testing.allocator,
//         ),
//     );
// }

// fn parseHallStatus(
//     buffer: []const u8,
//     a: std.mem.Allocator,
// ) !SystemState.Hall {
//     const HallStatus = protobuf_msg.HallStatus;
//     const response: HallStatus = try HallStatus.decode(
//         buffer,
//         a,
//     );
//     defer response.deinit();
//     const hall: SystemState.Hall = .{
//         .configured = response.configured,
//         .back = response.back,
//         .front = response.front,
//     };
//     return hall;
// }

// test parseHallStatus {
//     const hall: SystemState.Hall = .{
//         .configured = true,
//         .back = true,
//         .front = false,
//     };
//     const HallStatus = protobuf_msg.HallStatus;
//     var response: HallStatus = HallStatus.init(std.testing.allocator);
//     response = std.mem.zeroInit(HallStatus, .{});
//     defer response.deinit();
//     // Copy the value of y to the response
//     response = .{
//         .configured = true,
//         .back = true,
//         .front = false,
//     };
//     const encoded = try response.encode(std.testing.allocator);
//     defer std.testing.allocator.free(encoded);
//     try std.testing.expectEqual(
//         hall,
//         try parseHallStatus(
//             encoded,
//             std.testing.allocator,
//         ),
//     );
// }

// fn parseCommandStatus(
//     buffer: []const u8,
//     a: std.mem.Allocator,
// ) !SystemState.Command {
//     const CommandStatus = protobuf_msg.CommandStatus;
//     const response: CommandStatus = try CommandStatus.decode(
//         buffer,
//         a,
//     );
//     defer response.deinit();
//     // TODO: Find out why response_type != mcl.registers.Wr.CommandResponseCode
//     comptime var response_type: type = undefined;
//     inline for (@typeInfo(SystemState.Command).@"struct".fields) |field| {
//         if (comptime std.mem.eql(u8, "command_response", field.name)) {
//             response_type = field.type;
//             break;
//         }
//     }
//     const command_status: SystemState.Command = .{
//         .command_received = response.received,
//         .command_response = std.meta.stringToEnum(
//             response_type,
//             @tagName(response.response),
//         ).?,
//     };
//     return command_status;
// }

// test parseCommandStatus {
//     const com: SystemState.Command = .{
//         .command_received = true,
//         .command_response = .InvalidCommand,
//     };
//     const CommandStatus = protobuf_msg.CommandStatus;
//     var response: CommandStatus = CommandStatus.init(std.testing.allocator);
//     response = std.mem.zeroInit(CommandStatus, .{});
//     defer response.deinit();
//     // Copy the value of y to the response
//     response = .{
//         .received = true,
//         .response = .InvalidCommand,
//     };
//     const encoded = try response.encode(std.testing.allocator);
//     defer std.testing.allocator.free(encoded);
//     try std.testing.expectEqual(
//         com,
//         try parseCommandStatus(
//             encoded,
//             std.testing.allocator,
//         ),
//     );
// }

/// Check whether the socket has event flag occurred. Timeout is in milliseconds
/// unit.
fn isSocketEventOccured(socket: network.Socket, event: i16, timeout: i32) !bool {
    const fd: std.posix.pollfd = .{
        .fd = socket.internal,
        .events = event,
        .revents = 0,
    };
    var poll_fd: [1]std.posix.pollfd = .{fd};
    // check whether the expected socket event happen
    const status = std.posix.poll(
        &poll_fd,
        timeout,
    ) catch |e| {
        try disconnect();
        return e;
    };
    if (status == 0)
        return false
    else {
        std.log.debug("revents: {}", .{poll_fd[0].revents});
        // POLL.HUP: the peer gracefully close the socket
        if (poll_fd[0].revents & std.posix.POLL.HUP == std.posix.POLL.HUP)
            return error.ConnectionResetByPeer
        else if (poll_fd[0].revents & std.posix.POLL.ERR == std.posix.POLL.ERR)
            return error.ConnectionError
        else if (poll_fd[0].revents & std.posix.POLL.NVAL == std.posix.POLL.NVAL)
            return error.InvalidSocket
        else
            return true;
    }
}

/// Non-blocking receive from socket
fn receive(socket: network.Socket) ![]const u8 {
    // Check if the socket can read without blocking.
    var buffer: [8192]u8 = undefined;
    while (isSocketEventOccured(
        socket,
        std.posix.POLL.IN,
        0,
    )) |socket_status| {
        if (socket_status) break;
        // This step is required for reading from socket as the socket
        // may still receive some message from server. This message is no
        // longer valuable, thus ignored in the catch.
        command.checkCommandInterrupt() catch |e| {
            if (isSocketEventOccured(
                socket,
                std.posix.POLL.IN,
                5000,
            )) |_socket_status| {
                if (_socket_status)
                    // Remove any incoming messages, if any.
                    _ = socket.receive(&buffer) catch {
                        try disconnect();
                    };
                return e;
            } else |sock_err| {
                try disconnect();
                return sock_err;
            }
        };
    } else |sock_err| {
        try disconnect();
        return sock_err;
    }
    const msg_size = socket.receive(&buffer) catch |e| {
        try disconnect();
        return e;
    };
    // msg_size value 0 means the connection is gracefully closed
    if (msg_size == 0) {
        try disconnect();
        return error.ConnectionClosed;
    }
    std.log.debug(
        "received msg: {any}, length: {}",
        .{ buffer[0..msg_size], msg_size },
    );
    // TODO: Return with allocator dupe
    return buffer[0..msg_size];
}

fn send(socket: network.Socket, msg: []const u8) !void {
    // check if the socket can write without blocking
    while (isSocketEventOccured(
        socket,
        std.posix.POLL.OUT,
        0,
    )) |socket_status| {
        if (socket_status) break;
        try command.checkCommandInterrupt();
    } else |sock_err| {
        try disconnect();
        return sock_err;
    }
    socket.writer().writeAll(msg) catch |e| {
        try disconnect();
        return e;
    };
    std.log.debug(
        "sent msg: {any}, length: {}",
        .{ msg, msg.len },
    );
}
