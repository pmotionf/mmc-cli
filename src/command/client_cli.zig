const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");
const mmc = @import("mmc_config");
const protobuf_msg = mmc.protobuf_msg;
const protobuf = mmc.protobuf;
const SendCommand = protobuf_msg.SendCommand;
const Response = protobuf_msg.Response;
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

const Registers = struct {
    x: Response.RegisterX,
    y: Response.RegisterY,
    wr: Response.RegisterWr,
    ww: Response.RegisterWw,
};

const LoggingRegisters = struct {
    timestamp: f64,
    /// The maximum number of stations is 64 * 4
    registers: [64 * 4]Registers,
};

const Line = struct {
    index: u8,
    axes: []Axis,
    stations: []Station,
    name: []u8,
    speed: u5,
    acceleration: u8,
};

const Axis = struct {
    station: *const Station,
    index: Index,
    id: Id,
    const Index = struct {
        station: @This().Station,
        line: @This().Line,

        const Station = u2;
        const Line = u10;
    };
    const Id = Index;
};
const Station = struct {
    line: *const Line,
    index: u8,
    id: u9,
    axes: []Axis,
};

var lines: []Line = undefined;

var log_lines: []LogLine = undefined;

// TODO: Decide the value properly
var fba_buffer: [1_024_000]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const fba_allocator = fba.allocator();

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
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
        .execute = &clientAxisCarrier,
    });
    errdefer _ = command.registry.orderedRemove("AXIS_CARRIER");
    try command.registry.put(.{
        .name = "CARRIER_ID",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name(s)" },
            .{
                .name = "result variable prefix",
                .optional = true,
                .resolve = false,
            },
        },
        .short_description = "Display all carrier IDs on specified line(s).",
        .long_description =
        \\Scan the line, starting from the first axis, and print all recognized 
        \\carrier IDs on the given line in the order of their first appearance.
        \\This command support to scan multiple lines at once by providing line
        \\parameter with comma separator, e.g., "front,back,tr". If a result variable 
        \\prefix is provided, store all carrier IDs in the variable with the 
        \\variable name: prefix_[num], e.g., prefix_1 and prefix_2 if two carriers 
        \\exist on the provided line(s).
        ,
        .execute = &clientCarrierID,
    });
    errdefer command.registry.orderedRemove("CARRIER_ID");
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
    errdefer command.registry.orderedRemove("ASSERT_CARRIER_LOCATION");
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
            .{ .name = "line names", .optional = true },
        },
        .short_description = "Initialize all carriers automatically.",
        .long_description =
        \\Isolate all unisolated carriers on the provided lines and move the
        \\isolated carriers to a free space. If no line is provided, auto 
        \\initialize all unisolated carriers for all lines. Multiple lines should
        \\be separated by comma, e.g. "AUTO_INITIALIZE front,back"
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
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const version = switch (response.response orelse
            return error.UnexpectedResponse) {
            .server_version => |r| r,
            else => return error.UnexpectedResponse,
        };
        std.log.info("MMC Server Version: {d}.{d}.{d}\n", .{
            version.major,
            version.minor,
            version.patch,
        });
    } else {
        return error.NotConnected;
    }
}

fn clientConnect(params: [][]const u8) !void {
    std.log.debug("{}", .{params.len});
    if (main_socket) |socket| {
        if (isSocketEventOccurred(
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
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const line_config: Response.LineConfig = switch (response.response orelse
            return error.UnexpectedResponse) {
            .line_config => |r| r,
            else => return error.UnexpectedResponse,
        };
        lines = try allocator.alloc(Line, line_config.lines.items.len);
        log_lines = try allocator.alloc(LogLine, lines.len);
        for (line_config.lines.items, 0..) |line, line_idx| {
            lines[line_idx].axes = try allocator.alloc(
                Axis,
                @intCast(line.axes),
            );
            lines[line_idx].stations = try allocator.alloc(
                Station,
                @intCast(@divFloor(line.axes - 1, 3) + 1),
            );
            lines[line_idx].name = try allocator.alloc(
                u8,
                line.name.Owned.str.len,
            );
            lines[line_idx].acceleration = 78;
            lines[line_idx].speed = 12;
            lines[line_idx].index = @intCast(line_idx);
            var num_axes: usize = 0;
            @memcpy(lines[line_idx].name, line.name.getSlice());
            for (0..@intCast(@divFloor(line.axes - 1, 3) + 1)) |station_idx| {
                const start_num_axes = num_axes;
                for (0..3) |local_axis_idx| {
                    lines[line_idx].axes[num_axes] = .{
                        .station = &lines[line_idx].stations[station_idx],
                        .index = .{
                            .station = @intCast(local_axis_idx),
                            .line = @intCast(num_axes),
                        },
                        .id = .{
                            .station = @intCast(local_axis_idx + 1),
                            .line = @intCast(num_axes + 1),
                        },
                    };
                    num_axes += 1;
                }
                lines[line_idx].stations[station_idx] = .{
                    .axes = lines[line_idx].axes[start_num_axes..num_axes],
                    .line = &lines[line_idx],
                    .index = @intCast(station_idx),
                    .id = @intCast(station_idx + 1),
                };
            }
            // Initializing logging registers
            log_lines[line_idx].stations = .{false} ** 256;
            log_lines[line_idx].status = false;
        }
        std.log.info(
            "Received the line configuration for the following line:",
            .{},
        );
        const stdout = std.io.getStdOut().writer();
        for (lines) |line| {
            try stdout.writeByte('\t');
            try stdout.writeAll(line.name);
            try stdout.writeByte('\n');
        }
        for (lines) |line| {
            std.log.debug(
                "{s}:index {}:axes {}:stations {}:acc {}:speed {}",
                .{
                    line.name,
                    line.index,
                    line.axes.len,
                    line.stations.len,
                    line.acceleration,
                    line.speed,
                },
            );
        }
    } else {
        std.log.err("Failed to connect to server", .{});
    }
}

/// Free all memory EXCEPT the IP_Address, so that client can reconnect
fn disconnect() !void {
    if (main_socket) |s| {
        std.log.info(
            "Disconnecting from server {}",
            .{try s.getRemoteEndPoint()},
        );
        s.close();
        for (lines) |line| {
            allocator.free(line.axes);
            allocator.free(line.name);
            allocator.free(line.stations);
        }
        allocator.free(lines);
        allocator.free(log_lines);
        main_socket = null;
        lines = undefined;
        log_lines = undefined;
    } else return error.ServerNotConnected;
}

/// Serve as a callback of a `DISCONNECT` command, requires parameter.
fn clientDisconnect(_: [][]const u8) !void {
    try disconnect();
}

fn clientAutoInitialize(params: [][]const u8) !void {
    var init_lines = std.ArrayListAligned(
        SendCommand.AutoInitialize.Lines,
        null,
    ).init(fba_allocator);
    defer init_lines.deinit();
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try matchLine(lines, line_name);
            const _line = lines[line_idx];
            const line: SendCommand.AutoInitialize.Lines = .{
                .line_idx = @intCast(_line.index),
                .acceleration = @intCast(_line.acceleration),
                .speed = @intCast(_line.speed),
            };
            try init_lines.append(line);
        }
    } else {
        for (lines) |_line| {
            const line: SendCommand.AutoInitialize.Lines = .{
                .line_idx = @intCast(_line.index),
                .acceleration = @intCast(_line.acceleration),
                .speed = @intCast(_line.speed),
            };
            try init_lines.append(line);
        }
    }
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .auto_initialize = .{
                .lines = init_lines,
            },
        },
    };
    for (init_lines.items) |line| {
        std.log.debug(
            "idx: {}, speed: {}, acceleration: {}",
            .{ line.line_idx, line.speed, line.acceleration },
        );
    }
    const encoded = try command_msg.encode(fba_allocator);
    defer fba_allocator.free(encoded);
    try sendMessageAndWaitReceived(command_msg);
}

fn clientSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 3.0) return error.InvalidSpeed;

    const line_idx = try matchLine(lines, line_name);
    lines[line_idx].speed = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(lines[line_idx].speed)) / 10.0,
    });
}

fn clientSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 19.6)
        return error.InvalidAcceleration;

    const line_idx = try matchLine(lines, line_name);
    lines[line_idx].acceleration = @intFromFloat(carrier_acceleration * 10.0);

    std.log.info("Set acceleration to {d}m/s^2.", .{
        @as(f32, @floatFromInt(lines[line_idx].acceleration)) / 10.0,
    });
}

fn clientGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try matchLine(lines, line_name);
    std.log.info(
        "Line {s} speed: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(lines[line_idx].speed)) / 10.0,
        },
    );
}

fn clientGetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try matchLine(lines, line_name);
    std.log.info(
        "Line {s} acceleration: {d}m/s",
        .{
            line_name,
            @as(f32, @floatFromInt(lines[line_idx].acceleration)) / 10.0,
        },
    );
}

fn getRegister(
    line_idx: usize,
    axis_idx: usize,
    a: std.mem.Allocator,
    comptime reg_type: RegisterTypeCap,
) !@field(Response, std.fmt.comptimePrint("Register{s}", .{@tagName(reg_type)})) {
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(a);
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
        const encoded = try command_msg.encode(a);
        defer fba_allocator.free(encoded);
        std.log.debug(
            "message: {s}",
            .{@tagName(command_msg.command_kind.?)},
        );
        try send(s, encoded);
        const msg = try receive(s, a);
        defer fba_allocator.free(msg);
        const response = try parseResponse(msg, a);
        defer response.deinit();
        return switch (reg_type) {
            .X => response.response.?.x.dupe(a),
            .Y => response.response.?.y.dupe(a),
            .Wr => response.response.?.wr.dupe(a),
            .Ww => response.response.?.ww.dupe(a),
        };
    } else return error.ServerNotConnected;
}

fn clientStationX(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);
    const x = try getRegister(line_idx, axis_idx, fba_allocator, .X);
    defer x.deinit();
    _ = try mmc.nestedWrite("X", x, 0, std.io.getStdOut().writer());
}

fn clientStationY(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);
    const y = try getRegister(line_idx, axis_idx, fba_allocator, .Y);
    defer y.deinit();
    _ = try mmc.nestedWrite("Y", y, 0, std.io.getStdOut().writer());
}

fn clientStationWr(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);
    const wr = try getRegister(line_idx, axis_idx, fba_allocator, .Wr);
    defer wr.deinit();
    _ = try mmc.nestedWrite("Wr", wr, 0, std.io.getStdOut().writer());
}

fn clientStationWw(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);
    const ww = try getRegister(line_idx, axis_idx, fba_allocator, .Ww);
    defer ww.deinit();
    _ = try mmc.nestedWrite("Ww", ww, 0, std.io.getStdOut().writer());
}

fn clientAxisCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const result_var: []const u8 = params[2];
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
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
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const carrier = switch (response.response orelse
            return error.UnexpectedResponse) {
            .carrier => |r| r,
            else => return error.UnexpectedResponse,
        };
        if (carrier.id == 0) {
            std.log.info("No carrier recognized on axis {d}.\n", .{axis_id});
        } else {
            std.log.info(
                "Carrier {d} on axis {d}.\n",
                .{ carrier.id, axis_id },
            );
            if (result_var.len > 0) {
                var int_buf: [8]u8 = undefined;
                try command.variables.put(
                    result_var,
                    try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
                );
            }
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierID(params: [][]const u8) !void {
    var line_name_iterator = std.mem.tokenizeSequence(
        u8,
        params[0],
        ",",
    );
    const result_var: []const u8 = params[1];

    // Validate line names, avoid heap allocation
    var line_counter: usize = 0;
    while (line_name_iterator.next()) |line_name| {
        if (matchLine(lines, line_name)) |_| {
            line_counter += 1;
        } else |e| {
            std.log.info("Line {s} not found", .{line_name});
            return e;
        }
    }

    var line_idxs =
        std.ArrayList(usize).init(fba_allocator);
    defer line_idxs.deinit();
    line_name_iterator.reset();
    while (line_name_iterator.next()) |line_name| {
        try line_idxs.append(@intCast(try matchLine(
            lines,
            line_name,
        )));
    }

    var variable_count: usize = 1;
    for (line_idxs.items) |line_idx| {
        const line = lines[line_idx];
        for (line.stations) |station| {
            const wr: Response.RegisterWr = try getRegister(
                line_idx,
                station.axes[0].index.line,
                fba_allocator,
                .Wr,
            );
            const _carrier = wr.carrier.?;
            const ti = @typeInfo(@TypeOf(_carrier)).@"struct";
            inline for (ti.fields, 0..) |field, axis_idx| {
                const carrier: Response.RegisterWr.Carrier.Description =
                    @field(_carrier, field.name).?;
                if (carrier.id != 0) {
                    std.log.info(
                        "Carrier {d} on line {s} axis {d}",
                        .{
                            carrier.id,
                            lines[line_idx].name,
                            axis_idx + @as(usize, @intCast(station.index * 3)) + 1,
                        },
                    );
                    if (result_var.len > 0) {
                        var int_buf: [8]u8 = undefined;
                        // will fail if clients put ridiculously long prefix
                        var var_buf: [64]u8 = undefined;
                        const variable_key = try std.fmt.bufPrint(
                            &var_buf,
                            "{s}_{d}",
                            .{ result_var, variable_count },
                        );
                        const variable_value = try std.fmt.bufPrint(
                            &int_buf,
                            "{d}",
                            .{carrier.id},
                        );
                        var iterator = command.variables.iterator();
                        var isValueExists: bool = false;
                        while (iterator.next()) |entry| {
                            if (std.mem.eql(u8, variable_value, entry.value_ptr.*)) {
                                isValueExists = true;
                                break;
                            }
                        }
                        if (!isValueExists) {
                            try command.variables.put(
                                variable_key,
                                variable_value,
                            );
                            variable_count += 1;
                        }
                    }
                }
            }
        }
    }
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
    const line_idx = try matchLine(lines, line_name);

    if (main_socket) |s| {
        // Get carrier status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();
        command_msg = .{
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
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const carrier = switch (response.response orelse
            return error.UnexpectedResponse) {
            .carrier => |r| r,
            else => return error.UnexpectedResponse,
        };
        const location: f32 = carrier.location;
        if (location < expected_location - location_thr or
            location > expected_location + location_thr)
            return error.UnexpectedCarrierLocation;
    } else return error.ServerNotConnected;
}

fn clientAxisReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: usize = @intCast(axis_id - 1);
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .release_axis_servo = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_idx),
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientClearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];

    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis_id.? < 1 or axis_id.? > line.axes.len) return error.InvalidAxis;
    }
    const axis_idx: ?Axis.Index.Line = if (axis_id) |id|
        @intCast(id - 1)
    else
        null;
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
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
    try sendMessageAndWaitReceived(command_msg);
}

fn clientClearCarrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];

    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis_id.? < 1 or axis_id.? > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const axis_idx: ?Axis.Index.Line = if (axis_id) |id|
        @intCast(id - 1)
    else
        null;
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
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
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];

    const line_idx = try matchLine(lines, line_name);

    if (main_socket) |s| {
        // Get carrier status from the server

        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
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
        try send(s, encoded);
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const carrier = switch (response.response orelse
            return error.UnexpectedResponse) {
            .carrier => |r| r,
            else => return error.UnexpectedResponse,
        };
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
            if (result_var.len > 0) {
                var float_buf: [12]u8 = undefined;
                try command.variables.put(result_var, try std.fmt.bufPrint(
                    &float_buf,
                    "{d}",
                    .{carrier.location},
                ));
            }
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);
    if (main_socket) |s| {
        var command_msg: SendCommand = SendCommand.init(fba_allocator);
        defer command_msg.deinit();

        command_msg = .{
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
        try send(s, encoded);
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const carrier = switch (response.response orelse
            return error.UnexpectedResponse) {
            .carrier => |r| r,
            else => return error.UnexpectedResponse,
        };
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
            if (carrier.aux_axis == carrier.main_axis) return;
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, carrier.aux_axis + 1 },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientHallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    var axis_id: ?Axis.Id.Line = null;
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis_id.? < 1 or axis_id.? > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const axis_idx: ?Axis.Index.Line = if (axis_id != null)
        @intCast(axis_id.? - 1)
    else
        axis_id;

    if (main_socket) |s| {
        if (axis_idx) |idx| {
            // Get hall sensor status from the server

            var command_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_msg.deinit();

            command_msg = .{
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
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const hall = switch (response.response orelse
                return error.UnexpectedResponse) {
                .hall => |r| r,
                else => return error.UnexpectedResponse,
            };
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
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const hall = switch (response.response orelse
                return error.UnexpectedResponse) {
                .hall => |r| r,
                else => return error.UnexpectedResponse,
            };
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
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const side: Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .BACKWARD
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .FORWARD
        else
            return error.InvalidHallAlarmSide;
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis_idx: usize = @intCast(axis_id - 1);

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
        const msg = try receive(s, fba_allocator);
        defer fba_allocator.free(msg);
        const response: Response = try parseResponse(msg, fba_allocator);
        defer response.deinit();
        const hall = switch (response.response orelse
            return error.UnexpectedResponse) {
            .hall => |r| r,
            else => return error.UnexpectedResponse,
        };
        switch (side) {
            .BACKWARD => {
                if (hall.back != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
            .FORWARD => {
                if (hall.front != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
            else => unreachable,
        }
    } else return error.ServerNotConnected;
}

fn clientMclReset(_: [][]const u8) !void {
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .reset_mcl = .{},
        },
    };
    const encoded = try command_msg.encode(fba_allocator);
    defer fba_allocator.free(encoded);
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .calibrate = .{
                .line_idx = @intCast(line_idx),
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientSetLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .set_line_zero = .{
                .line_idx = @intCast(line_idx),
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    const dir: protobuf_msg.Direction = dir_parse: {
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
    const link_axis: protobuf_msg.Direction = link: {
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

    const axis_idx: Axis.Index.Line = @intCast(axis_id - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .isolate_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_idx),
                .carrier_id = carrier_id,
                .link_axis = link_axis,
                .direction = dir,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientWaitIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);

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
            try send(s, encoded);
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const carrier = switch (response.response orelse
                return error.UnexpectedResponse) {
                .carrier => |r| r,
                else => return error.UnexpectedResponse,
            };
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

    const line_idx = try matchLine(lines, line_name);

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
            try send(s, encoded);
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const carrier = switch (response.response orelse
                return error.UnexpectedResponse) {
                .carrier => |r| r,
                else => return error.UnexpectedResponse,
            };
            if (carrier.state == .POS_MOVE_COMPLETED or
                carrier.state == .SPD_MOVE_COMPLETED) return;
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .axis_id = @intCast(axis_id) },
                .move_type = .POSITION_AXIS,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .location_distance = location },
                .move_type = .POSITION_LOCATION,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
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
    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .location_distance = distance },
                .move_type = .POSITION_DISTANCE,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[2], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .axis_id = @intCast(axis_id) },
                .move_type = .SPEED_AXIS,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .location_distance = location },
                .move_type = .SPEED_LOCATION,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx = try matchLine(lines, line_name);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .move_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{ .location_distance = distance },
                .move_type = .SPEED_DISTANCE,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_axis: ?i32 = null;
    if (axis_id) |id| {
        const line = lines[line_idx];
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        const axis = line.axes[id - 1];
        command_axis = @intCast(axis.index.line);
    }
    command_msg = .{
        .command_kind = .{
            .push_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .direction = .FORWARD,
                .axis_idx = command_axis,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_id: ?Axis.Id.Line = if (params[2].len > 0)
        try std.fmt.parseInt(Axis.Id.Line, params[2], 0)
    else
        null;

    const line_idx = try matchLine(lines, line_name);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    var command_axis: ?i32 = null;
    if (axis_id) |id| {
        const line = lines[line_idx];
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        const axis = line.axes[id - 1];
        command_axis = @intCast(axis.index.line);
    }
    command_msg = .{
        .command_kind = .{
            .push_carrier = .{
                .line_idx = @intCast(line_idx),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .direction = .BACKWARD,
                .axis_idx = command_axis,
            },
        },
    };

    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: Axis.Index.Line = @intCast(axis - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .pull_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .direction = .FORWARD,
                .destination = destination,
            },
        },
    };

    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: Axis.Index.Line = @intCast(axis - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();
    command_msg = .{
        .command_kind = .{
            .pull_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
                .carrier_id = carrier_id,
                .speed = @intCast(lines[line_idx].speed),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .direction = .BACKWARD,
                .destination = destination,
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierWaitPull(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);

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
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const carrier = switch (response.response orelse
                return error.UnexpectedResponse) {
                .carrier => |r| r,
                else => return error.UnexpectedResponse,
            };
            if (carrier.state == .PULL_FORWARD_COMPLETED or
                carrier.state == .PULL_BACKWARD_COMPLETED) return;
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis_index: Axis.Index.Line = @intCast(axis_id - 1);

    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
        .command_kind = .{
            .stop_pull_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientCarrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis_index: Axis.Index.Line = @intCast(axis_id - 1);
    var command_msg: SendCommand = SendCommand.init(fba_allocator);
    defer command_msg.deinit();

    command_msg = .{
        .command_kind = .{
            .stop_push_carrier = .{
                .line_idx = @intCast(line_idx),
                .axis_idx = @intCast(axis_index),
            },
        },
    };
    try sendMessageAndWaitReceived(command_msg);
}

fn clientWaitAxisEmpty(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const timeout = if (params[2].len > 0)
        try std.fmt.parseInt(u64, params[2], 0)
    else
        0;
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis_idx = axis_id - 1;
    const local_axis: u2 = @intCast(axis_idx % 3);

    // const axis: mcl.Axis = line.axes[axis_id - 1];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        const wr: Response.RegisterWr = try getRegister(
            line_idx,
            axis_idx,
            fba_allocator,
            .Wr,
        );
        const x: Response.RegisterX = try getRegister(
            line_idx,
            axis_idx,
            fba_allocator,
            .X,
        );
        const carrier = mmc.getAxisInfo(
            Response.RegisterWr.Carrier.Description,
            wr.carrier.?,
            local_axis,
        );
        const axis_alarms = mmc.getAxisInfo(
            Response.RegisterX.HallAlarm.Side,
            x.hall_alarm.?,
            local_axis,
        );
        const wait_push = mmc.getAxisInfo(
            bool,
            x.wait_push_carrier.?,
            local_axis,
        );
        const wait_pull = mmc.getAxisInfo(
            bool,
            x.wait_pull_carrier.?,
            local_axis,
        );
        if (carrier.id == 0 and !axis_alarms.back and !axis_alarms.front and
            !wait_pull and !wait_push)
        {
            break;
        }
    }
}

/// Add logging configuration for registers logging in the specified line
fn addLogRegisters(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];

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
        const axis_id = try std.fmt.parseInt(Axis.Id.Line, token, 0);

        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const axis_index: usize = @intCast(axis_id - 1);
        const station_index: usize = @intCast(axis_index / 3);
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
    const line_idx = try matchLine(lines, line_name);

    if (log_lines[line_idx].status == false) {
        std.log.err("Line is not configured for logging yet", .{});
        return;
    }

    log_lines[line_idx].status = false;
}

fn resetLogRegisters(_: [][]const u8) !void {
    for (lines) |line| {
        log_lines[line.index].status = false;
    }
}

fn statusLogRegisters(_: [][]const u8) !void {
    var buffer: [8192]u8 = undefined;
    var buf_len: usize = 0;
    // flag to indicate printing ","
    var first = true;
    for (lines) |line| {
        // Section to print line name
        if (log_lines[line.index].status == false) continue;
        buf_len += (try std.fmt.bufPrint(
            buffer[buf_len..],
            "{s}:",
            .{line.name},
        )).len;
        // Section to print station index
        first = true;
        for (0..log_lines[line.index].stations.len) |station_idx| {
            if (log_lines[line.index].stations[station_idx] == false) continue;
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
        var reg_iterator = log_lines[line.index].registers.iterator();
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
    for (lines) |line| {
        if (log_lines[line.index].status == true) {
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

    for (lines) |line| {
        if (log_lines[line.index].status == false) continue;
        for (0..256) |station_idx| {
            if (log_lines[line.index].stations[station_idx] == false) continue;
            var reg_iterator = log_lines[line.index].registers.iterator();
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
                                .{ line.name, station_idx + 1, reg_enum.name },
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
    defer logging_data.deinit();
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
        for (lines) |line| {
            if (log_lines[line.index].status == false) continue;
            for (0..256) |station_idx| {
                if (log_lines[line.index].stations[station_idx] == false) continue;
                var reg_iterator = log_lines[line.index].registers.iterator();
                var command_code: Response.RegisterWw.CommandCode = .COMMAND_CODE_UNSPECIFIED;
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
    command_code: *Response.RegisterWw.CommandCode,
) !void {
    const parent_ti = @typeInfo(@TypeOf(parent)).@"struct";
    inline for (parent_ti.fields) |child_field| {
        if (comptime @typeInfo(child_field.type) == .optional and
            @typeInfo(@typeInfo(child_field.type).optional.child) != .@"union")
        {
            try registerValueToString(
                @field(parent, child_field.name).?,
                writer,
                command_code,
            );
        } else {
            if (comptime @typeInfo(child_field.type) == .@"enum") {
                const child_value = @field(parent, child_field.name);
                if (child_field.type == Response.RegisterWw.CommandCode) {
                    command_code.* = child_value;
                }
                try writer.print("{d},", .{@intFromEnum(child_value)});
            } else if (@typeInfo(child_field.type) == .optional and
                @typeInfo(@typeInfo(child_field.type).optional.child) == .@"union")
            {
                const child_value = @field(parent, child_field.name).?;
                switch (child_value) {
                    inline else => |_, tag| {
                        std.log.debug("union tag {s}", .{@tagName(tag)});
                        const union_val = @field(child_value, @tagName(tag));
                        try writer.print("{d},", .{union_val});
                    },
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
    for (lines) |line| {
        if (log_lines[line.index].status == false) continue;
        for (line.stations) |station| {
            const axis_idx = station.axes[0].index.line;
            if (log_lines[line.index].stations[station.index] == false) continue;
            var reg_iterator = log_lines[line.index].registers.iterator();
            while (reg_iterator.next()) |reg_entry| {
                const reg_type = @TypeOf(reg_entry.key);
                inline for (@typeInfo(reg_type).@"enum".fields) |reg_enum| {
                    if (@intFromEnum(reg_entry.key) == reg_enum.value and
                        reg_entry.value.* == true)
                    {
                        switch (reg_entry.key) {
                            .x => {
                                result.registers[reg_idx].x = try getRegister(
                                    line.index,
                                    axis_idx,
                                    fba_allocator,
                                    .X,
                                );
                            },
                            .y => {
                                result.registers[reg_idx].y = try getRegister(
                                    line.index,
                                    axis_idx,
                                    fba_allocator,
                                    .Y,
                                );
                            },
                            .wr => {
                                result.registers[reg_idx].wr = try getRegister(
                                    line.index,
                                    axis_idx,
                                    fba_allocator,
                                    .Wr,
                                );
                            },
                            .ww => {
                                result.registers[reg_idx].ww = try getRegister(
                                    line.index,
                                    axis_idx,
                                    fba_allocator,
                                    .Ww,
                                );
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
        if (@typeInfo(child_field.type) == .optional and
            @typeInfo(@typeInfo(child_field.type).optional.child) != .@"union")
        {
            if (parent.len == 0) {
                try writeLoggingHeaders(
                    writer,
                    prefix,
                    child_field.name,
                    @typeInfo(child_field.type).optional.child,
                );
            } else {
                try writeLoggingHeaders(
                    writer,
                    prefix,
                    parent ++ "." ++ child_field.name,
                    @typeInfo(child_field.type).optional.child,
                );
            }
        } else {
            if (parent.len == 0) {
                try writer.print(
                    "{s}_{s},",
                    .{ prefix, child_field.name },
                );
            } else {
                try writer.print(
                    "{s}_{s},",
                    .{ prefix, parent ++ "." ++ child_field.name },
                );
            }
        }
    }
}

fn matchLine(_lines: []Line, name: []const u8) !usize {
    for (_lines) |line| {
        if (std.mem.eql(u8, line.name, name)) return line.index;
    } else return error.LineNameNotFound;
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
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            command_id = switch (response.response orelse
                return error.UnexpectedResponse) {
                .command_id => |r| r.command_id,
                else => return error.UnexpectedResponse,
            };
        }
        while (true) {
            try command.checkCommandInterrupt();
            var command_status_msg: SendCommand = SendCommand.init(fba_allocator);
            defer command_status_msg.deinit();
            command_status_msg = .{
                .command_kind = .{
                    .get_command_status = .{ .command_id = command_id },
                },
            };
            const encoded = try command_status_msg.encode(fba_allocator);
            defer fba_allocator.free(encoded);
            try send(s, encoded);
            const msg = try receive(s, fba_allocator);
            defer fba_allocator.free(msg);
            const response: Response = try parseResponse(msg, fba_allocator);
            defer response.deinit();
            const command_status = switch (response.response orelse
                return error.UnexpectedResponse) {
                .command_status => |r| r,
                else => return error.UnexpectedResponse,
            };
            switch (command_status.status) {
                .PROCESSING, .QUEUED => {}, // continue the loop
                .COMPLETED => break,
                .FAILED => {}, // handled by parseResponse()
                else => return error.UnexpectedResponse,
            }
        }
    } else return error.ServerNotConnected;
}

/// Check server response. Return error if the response is a error message.
fn parseResponse(msg: []const u8, a: std.mem.Allocator) !Response {
    const response: Response = try Response.decode(msg, a);
    errdefer response.deinit();
    switch (response.response.?) {
        .command_status => |r| {
            if (r.status != .FAILED) return try response.dupe(a);
            const _response = r.error_response orelse return error.Unexpected;
            return switch (_response) {
                .ERROR_UNSPECIFIED, .UNEXPECTED => error.Unexpected,
                .CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .VDC_UNDERVOLTAGE_DETECTED => error.VDCUndervoltageDetected,
                .VDC_OVERVOLTAGE_DETECTED => error.VDCOvervoltageDetected,
                .COMMUNICATION_ERROR_DETECTED => error.CommunicationErrorDetected,
                .INVERTER_OVERHEAT_DETECTED => error.InverterOverheatDetected,
                .OVERCURRENT_DETECTED => error.OvercurrentDetected,
                .INVALID_COMMAND => error.InvalidCommand,
                .CARRIER_NOT_FOUND => error.CarrierNotFound,
                .HOMING_FAILED => error.HomingFailed,
                .INVALID_PARAMETER => error.InvalidParameter,
                .INVALID_SYSTEM_STATE => error.InvalidSystemState,
                .CARRIER_ALREADY_EXISTS => error.CarrierAlreadyExists,
                .CONTROL_LOOP_MAX_TIME_EXCEEDED => error.ControlLoopMaxTimeExceeded,
                .INVALID_AXIS => error.InvalidAxis,
                // zig decided to force else or `_` prong
                _ => unreachable,
            };
        },
        else => return try response.dupe(a),
    }
}

/// Check whether the socket has event flag occurred. Timeout is in milliseconds
/// unit.
fn isSocketEventOccurred(socket: network.Socket, event: i16, timeout: i32) !bool {
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
fn receive(socket: network.Socket, a: std.mem.Allocator) ![]const u8 {
    // Check if the socket can read without blocking.
    var buffer: [8192]u8 = undefined;
    while (isSocketEventOccurred(
        socket,
        std.posix.POLL.IN,
        0,
    )) |socket_status| {
        // This step is required for reading from socket as the socket
        // may still receive some message from server. This message is no
        // longer valuable, thus ignored in the catch.
        command.checkCommandInterrupt() catch |e| {
            if (isSocketEventOccurred(
                socket,
                std.posix.POLL.IN,
                500,
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
        if (socket_status) break;
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
    return a.dupe(u8, buffer[0..msg_size]);
}

fn send(socket: network.Socket, msg: []const u8) !void {
    // check if the socket can write without blocking
    while (isSocketEventOccurred(
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
