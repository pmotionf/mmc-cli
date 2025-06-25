const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");
const api = @import("mmc-api");
const Direction = api.command_msg.Direction;
const CommandRequest = api.command_msg.Request;
const CommandResponse = api.command_msg.Response;
const InfoRequest = api.info_msg.Request;
const InfoResponse = api.info_msg.Response;
const CoreRequest = api.core_msg.Request;
const CoreResponse = api.core_msg.Response;
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
    x: InfoResponse.RegisterX,
    y: InfoResponse.RegisterY,
    wr: InfoResponse.RegisterWr,
    ww: InfoResponse.RegisterWw,
};

const LoggingRegisters = struct {
    timestamp: f64,
    /// The maximum number of stations is 64 * 4
    registers: [64 * 4]Registers,
};

const Line = struct {
    index: Line.Index,
    id: Line.Id,
    axes: []Axis,
    stations: []Station,
    name: []u8,
    velocity: u5,
    acceleration: u8,

    pub const Index = Station.Index;
    pub const Id = Station.Id;
};

const Axis = struct {
    station: *const Station,
    index: Index,
    id: Id,
    pub const Index = struct {
        line: Axis.Index.Line,
        station: Axis.Index.Station,

        pub const Line = std.math.IntFittingRange(0, 64 * 4 * 3 - 1);
        pub const Station = std.math.IntFittingRange(0, 2);
    };

    pub const Id = struct {
        line: Axis.Id.Line,
        station: Axis.Id.Station,

        pub const Line = std.math.IntFittingRange(1, 64 * 4 * 3);
        pub const Station = std.math.IntFittingRange(1, 3);
    };
};

const Station = struct {
    line: *const Line,
    index: Station.Index,
    id: Station.Id,
    axes: []Axis,

    pub const Index = std.math.IntFittingRange(0, 64 * 4 - 1);
    pub const Id = std.math.IntFittingRange(1, 64 * 4);
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
        getLineConfig() catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            return try disconnect();
        };
        assertAPIVersion() catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            return try disconnect();
        };
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

fn clientSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 3.0) return error.InvalidSpeed;

    const line_idx = try matchLine(lines, line_name);
    lines[line_idx].velocity = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(lines[line_idx].velocity)) / 10.0,
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
            @as(f32, @floatFromInt(lines[line_idx].velocity)) / 10.0,
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

fn serverVersion(_: [][]const u8) !void {
    var core_msg: CoreRequest = CoreRequest.init(fba_allocator);
    defer core_msg.deinit();
    core_msg.kind = .CORE_REQUEST_KIND_SERVER_INFO;
    const server = try sendRequest(
        core_msg,
        fba_allocator,
        CoreResponse.Server,
    );
    const version = server.version.?;
    defer server.deinit();
    std.log.info(
        "MMC Server Version: {d}.{d}.{d}\n",
        .{ version.major, version.minor, version.patch },
    );
    std.log.debug("Server name: {s}", .{server.name.getSlice()});
}

/// Request api version used by the server. Called inside connect function and
/// return the API version.
fn APIVersion() !std.SemanticVersion {
    var core_msg: CoreRequest = CoreRequest.init(fba_allocator);
    defer core_msg.deinit();
    core_msg.kind = .CORE_REQUEST_KIND_API_VERSION;
    const version = try sendRequest(
        core_msg,
        fba_allocator,
        CoreResponse.SemanticVersion,
    );
    defer version.deinit();
    return .{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
    };
}

/// Request line configurataion from the server. Called inside connect command
fn getLineConfig() !void {
    var core_msg: CoreRequest = CoreRequest.init(fba_allocator);
    defer core_msg.deinit();
    core_msg.kind = .CORE_REQUEST_KIND_LINE_CONFIG;
    const response = try sendRequest(
        core_msg,
        fba_allocator,
        CoreResponse.LineConfig,
    );
    defer response.deinit();

    const line_config = response.lines.items;
    lines = try allocator.alloc(Line, line_config.len);
    log_lines = try allocator.alloc(LogLine, lines.len);
    for (line_config, 0..) |line, line_idx| {
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
        lines[line_idx].velocity = 12;
        lines[line_idx].index = @intCast(line_idx);
        lines[line_idx].id = @intCast(line_idx + 1);
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
                line.velocity,
            },
        );
    }
}

/// Assert that the API versions used in mmc-cli and mmc server are identical
/// for major and minor version
fn assertAPIVersion() !void {
    var core_msg: CoreRequest = CoreRequest.init(fba_allocator);
    defer core_msg.deinit();
    core_msg.kind = .CORE_REQUEST_KIND_API_VERSION;
    const server_api_version = try sendRequest(
        core_msg,
        fba_allocator,
        CoreResponse.SemanticVersion,
    );
    const cli_api_version = api.version;
    if (cli_api_version.major != server_api_version.major or
        cli_api_version.minor != server_api_version.minor)
    {
        return error.APIVersionMismatch;
    }
    std.log.debug(
        "server api version: {}.{}.{}",
        .{
            server_api_version.major,
            server_api_version.minor,
            server_api_version.patch,
        },
    );
    std.log.debug(
        "client api version: {}.{}.{}",
        .{
            cli_api_version.major,
            cli_api_version.minor,
            cli_api_version.patch,
        },
    );
}

fn clientAutoInitialize(params: [][]const u8) !void {
    var init_lines = std.ArrayListAligned(
        CommandRequest.AutoInitialize.Lines,
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
            const line: CommandRequest.AutoInitialize.Lines = .{
                .line_id = @intCast(_line.id),
                .acceleration = @intCast(_line.acceleration),
                .velocity = @intCast(_line.velocity),
            };
            try init_lines.append(line);
        }
    } else {
        for (lines) |_line| {
            const line: CommandRequest.AutoInitialize.Lines = .{
                .line_id = @intCast(_line.id),
                .acceleration = @intCast(_line.acceleration),
                .velocity = @intCast(_line.velocity),
            };
            try init_lines.append(line);
        }
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .auto_initialize = .{ .lines = init_lines },
    };
    for (init_lines.items) |line| {
        std.log.debug(
            "id: {}, speed: {}, acceleration: {}",
            .{ line.line_id, line.velocity, line.acceleration },
        );
    }
    const encoded = try command_msg.encode(fba_allocator);
    defer fba_allocator.free(encoded);
    try sendCommandRequest(command_msg, fba_allocator);
}

fn getRegister(
    line_id: Line.Id,
    station_id: Station.Id,
    a: std.mem.Allocator,
    comptime reg_type: RegisterTypeCap,
) !@field(InfoResponse, std.fmt.comptimePrint(
    "Register{s}",
    .{@tagName(reg_type)},
)) {
    var info_msg: InfoRequest = InfoRequest.init(a);
    defer info_msg.deinit();
    comptime var _buf: [2]u8 = undefined;
    const union_field_name = "register_" ++ comptime std.ascii.lowerString(
        &_buf,
        @tagName(reg_type),
    );
    info_msg.body = @unionInit(
        InfoRequest.body_union,
        union_field_name,
        .{
            .line_id = line_id,
            .station_id = station_id,
        },
    );
    return switch (reg_type) {
        .X => try sendRequest(info_msg, fba_allocator, InfoResponse.RegisterX),
        .Y => try sendRequest(info_msg, fba_allocator, InfoResponse.RegisterY),
        .Wr => try sendRequest(info_msg, fba_allocator, InfoResponse.RegisterWr),
        .Ww => try sendRequest(info_msg, fba_allocator, InfoResponse.RegisterWw),
    };
}

fn clientStationX(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    const x = try getRegister(line.id, station.id, fba_allocator, .X);
    _ = try api.nestedWrite("X", x, 0, std.io.getStdOut().writer());
}

fn clientStationY(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    const y = try getRegister(line.id, station.id, fba_allocator, .Y);
    _ = try api.nestedWrite("Y", y, 0, std.io.getStdOut().writer());
}

fn clientStationWr(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    const wr = try getRegister(line.id, station.id, fba_allocator, .Wr);
    _ = try api.nestedWrite("Wr", wr, 0, std.io.getStdOut().writer());
}

fn clientStationWw(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis = line.axes[axis_id - 1];
    const station = axis.station;
    const ww = try getRegister(line.id, station.id, fba_allocator, .Ww);
    _ = try api.nestedWrite("Ww", ww, 0, std.io.getStdOut().writer());
}

fn clientAxisCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const result_var: []const u8 = params[2];
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    info_msg.body = .{
        .carrier = .{
            .line_id = @intCast(line.id),
            .param = .{ .axis_id = @intCast(axis_id) },
        },
    };
    const carrier = sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.Carrier,
    ) catch |e| {
        if (e == error.CarrierNotFound) {
            std.log.info("No carrier recognized on axis {d}.\n", .{axis_id});
            return;
        } else return e;
    };
    defer carrier.deinit();
    std.log.info("Carrier {d} on axis {d}.\n", .{ carrier.id, axis_id });
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{carrier.id}),
        );
    }
}

fn clientCarrierID(params: [][]const u8) !void {
    var line_name_iterator = std.mem.tokenizeSequence(
        u8,
        params[0],
        ",",
    );
    const result_var: []const u8 = params[1];
    if (result_var.len > 32) return error.PrefixTooLong;

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
            const wr: InfoResponse.RegisterWr = try getRegister(
                line.id,
                station.id,
                fba_allocator,
                .Wr,
            );
            const _carrier = wr.carrier.?;
            const ti = @typeInfo(@TypeOf(_carrier)).@"struct";
            inline for (ti.fields, 0..) |field, axis_idx| {
                const carrier: InfoResponse.RegisterWr.Carrier.Description =
                    @field(_carrier, field.name).?;
                if (carrier.id != 0) {
                    std.log.info(
                        "Carrier {d} on line {s} axis {d}",
                        .{
                            carrier.id,
                            line.name,
                            axis_idx + @as(usize, @intCast(station.index * 3)) + 1,
                        },
                    );
                    if (result_var.len > 0) {
                        var int_buf: [8]u8 = undefined;
                        var var_buf: [36]u8 = undefined;
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
    const line = lines[line_idx];
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    info_msg.body = .{
        .carrier = .{
            .line_id = @intCast(line.id),
            .param = .{ .carrier_id = carrier_id },
        },
    };
    const carrier = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.Carrier,
    );
    const location: f32 = carrier.location;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
}

fn clientAxisReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    const axis = line.axes[axis_id - 1];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .release_axis_servo = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis.id.line),
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .clear_errors = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |id| @intCast(id) else null,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .clear_carrier_info = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |id| @intCast(id) else null,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();

    info_msg.body = .{
        .carrier = .{
            .line_id = @intCast(line.id),
            .param = .{ .carrier_id = @intCast(carrier_id) },
        },
    };
    const carrier = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.Carrier,
    );
    defer carrier.deinit();
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

fn clientCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    info_msg.body = .{
        .carrier = .{
            .line_id = @intCast(line.id),
            .param = .{ .carrier_id = @intCast(carrier_id) },
        },
    };
    const carrier = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.Carrier,
    );
    defer carrier.deinit();
    std.log.info(
        "Carrier {d} axis: {}",
        .{ carrier.id, carrier.main_axis_id },
    );
    if (carrier.aux_axis_id == carrier.main_axis_id) return;
    std.log.info(
        "Carrier {d} axis: {}",
        .{ carrier.id, carrier.aux_axis_id },
    );
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

    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    if (axis_id) |axis| {
        info_msg.body = .{
            .hall_alarm = .{
                .line_id = @intCast(line.id),
                .axis_id = axis,
            },
        };
        const hall = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.HallAlarm,
        );
        defer hall.deinit();
        std.log.info(
            "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
            .{
                axis_id.?,
                if (hall.back) "ON" else "OFF",
                if (hall.front) "ON" else "OFF",
            },
        );
    } else {
        for (line.axes) |axis| {
            info_msg.body = .{
                .hall_alarm = .{
                    .line_id = @intCast(line.id),
                    .axis_id = @intCast(axis.id.line),
                },
            };
            const hall = try sendRequest(
                info_msg,
                fba_allocator,
                InfoResponse.HallAlarm,
            );
            defer hall.deinit();
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id.line,
                    if (hall.back) "ON" else "OFF",
                    if (hall.front) "ON" else "OFF",
                },
            );
        }
    }
}

fn clientAssertHall(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const side: Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .DIRECTION_BACKWARD
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .DIRECTION_FORWARD
        else
            return error.InvalidHallAlarmSide;
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
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

    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();

    info_msg.body = .{
        .hall_alarm = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
        },
    };
    const hall = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.HallAlarm,
    );
    defer hall.deinit();
    switch (side) {
        .DIRECTION_BACKWARD => {
            if (hall.back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .DIRECTION_FORWARD => {
            if (hall.front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        else => return error.UnexpectedResponse,
    }
}

fn clientMclReset(_: [][]const u8) !void {
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{ .reset_mcl = .{} };
    const encoded = try command_msg.encode(fba_allocator);
    defer fba_allocator.free(encoded);
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .calibrate = .{ .line_id = @intCast(line.id) },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientSetLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .set_line_zero = .{ .line_id = @intCast(line.id) },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientIsolate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    const dir: Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .DIRECTION_FORWARD;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .DIRECTION_BACKWARD;
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
                break :link .DIRECTION_FORWARD;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .DIRECTION_BACKWARD;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link .DIRECTION_UNSPECIFIED;
    };

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .isolate_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
            .carrier_id = carrier_id,
            .link_axis = link_axis,
            .direction = dir,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const line = lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        info_msg.body = .{
            .carrier = .{
                .line_id = @intCast(line.id),
                .param = .{
                    .carrier_id = @intCast(carrier_id),
                },
            },
        };
        const carrier = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.Carrier,
        );
        defer carrier.deinit();
        if (carrier.state == .STATE_BACKWARD_ISOLATION_COMPLETED or
            carrier.state == .STATE_FORWARD_ISOLATION_COMPLETED) return;
    }
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
    const line = lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        info_msg.body = .{
            .carrier = .{
                .line_id = @intCast(line.id),
                .param = .{
                    .carrier_id = carrier_id,
                },
            },
        };
        const carrier = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.Carrier,
        );
        defer carrier.deinit();
        if (carrier.state == .STATE_POS_MOVE_COMPLETED or
            carrier.state == .STATE_SPD_MOVE_COMPLETED) return;
    }
}

fn clientCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .axis = @intCast(axis_id) },
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .location = location },
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .distance = distance },
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .axis = @intCast(axis_id) },
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .location = location },
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .distance = distance },
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    var command_axis: ?u32 = null;
    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        command_axis = @intCast(id);
    }
    command_msg.body = .{
        .push_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .direction = .DIRECTION_FORWARD,
            .axis_id = command_axis,
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    var command_axis: ?u32 = null;
    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        command_axis = @intCast(id);
    }
    command_msg.body = .{
        .push_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .direction = .DIRECTION_BACKWARD,
            .axis_id = command_axis,
        },
    };

    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .pull_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .direction = .DIRECTION_FORWARD,
            .target = blk: {
                if (destination) |location|
                    break :blk .{ .location = location }
                else
                    break :blk null;
            },
        },
    };

    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const destination: ?f32 = if (params[3].len > 0)
        try std.fmt.parseFloat(f32, params[3])
    else
        null;

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .pull_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .direction = .DIRECTION_BACKWARD,
            .target = blk: {
                if (destination) |location|
                    break :blk .{ .location = location }
                else
                    break :blk null;
            },
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const line = lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        info_msg.body = .{
            .carrier = .{
                .line_id = @intCast(line.id),
                .param = .{ .carrier_id = @intCast(carrier_id) },
            },
        };
        const carrier = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.Carrier,
        );
        defer carrier.deinit();
        if (carrier.state == .STATE_PULL_FORWARD_COMPLETED or
            carrier.state == .STATE_PULL_BACKWARD_COMPLETED) return;
    }
}

fn clientCarrierStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();

    command_msg.body = .{
        .stop_pull_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
}

fn clientCarrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) return error.InvalidAxis;
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();

    command_msg.body = .{
        .stop_push_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = @intCast(axis_id),
        },
    };
    try sendCommandRequest(command_msg, fba_allocator);
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
    const axis = line.axes[axis_id - 1];

    // const axis: mcl.Axis = line.axes[axis_id - 1];

    var wait_timer = try std.time.Timer.start();
    while (true) {
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
        info_msg.body = .{
            .axis = .{
                .line_id = @intCast(line.id),
                .range = .{
                    .start_id = @intCast(axis.id.line),
                    .end_id = @intCast(axis.id.line),
                },
            },
        };
        const response = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.Axes,
        );
        defer response.deinit();
        const axis_info = response.axes.items[0];
        const carrier = axis_info.carrier_id;
        const axis_alarms = axis_info.hall_alarm.?;
        const wait_push = axis_info.waiting_push;
        const wait_pull = axis_info.waiting_pull;
        if (carrier == 0 and !axis_alarms.back and !axis_alarms.front and
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
                var command_code: InfoResponse.RegisterWw.CommandCode = .COMMAND_CODE_UNSPECIFIED;
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
    command_code: *InfoResponse.RegisterWw.CommandCode,
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
                if (child_field.type == InfoResponse.RegisterWw.CommandCode) {
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
                                    line.id,
                                    station.id,
                                    fba_allocator,
                                    .X,
                                );
                            },
                            .y => {
                                result.registers[reg_idx].y = try getRegister(
                                    line.id,
                                    station.id,
                                    fba_allocator,
                                    .Y,
                                );
                            },
                            .wr => {
                                result.registers[reg_idx].wr = try getRegister(
                                    line.id,
                                    station.id,
                                    fba_allocator,
                                    .Wr,
                                );
                            },
                            .ww => {
                                result.registers[reg_idx].ww = try getRegister(
                                    line.id,
                                    station.id,
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

/// Send a request to the server and retrieve the response. Response that requires
/// memory need to free the memory
fn sendRequest(
    /// `body` type should be one of CoreRequest, CommandRequest, or InfoRequest
    body: anytype,
    a: std.mem.Allocator,
    comptime T: type,
) !T {
    if (main_socket) |s| {
        var encoded: []u8 = undefined;
        if (@TypeOf(body) == CoreRequest) {
            const _msg: api.mmc_msg.Request = .{ .body = .{ .core = body } };
            encoded = try _msg.encode(a);
        }
        if (@TypeOf(body) == InfoRequest) {
            const _msg: api.mmc_msg.Request = .{ .body = .{ .info = body } };
            encoded = try _msg.encode(a);
        }
        if (@TypeOf(body) == CommandRequest) {
            const _msg: api.mmc_msg.Request = .{ .body = .{ .command = body } };
            encoded = try _msg.encode(a);
        }
        defer a.free(encoded);
        try send(s, encoded);
        const rep = try receive(s, a);
        defer a.free(rep);
        return try parseResponse(a, T, rep);
    } else return error.ServerNotConnected;
}

/// Send a command request and wait for its response to arrive
fn sendCommandRequest(
    command_msg: CommandRequest,
    a: std.mem.Allocator,
) !void {
    const command_id = try sendRequest(
        command_msg,
        a,
        u32,
    );
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        try command.checkCommandInterrupt();
        info_msg.body = .{
            .command = .{ .command_id = command_id },
        };
        const command_status = try sendRequest(
            info_msg,
            a,
            InfoResponse.Command,
        );
        defer command_status.deinit();
        switch (command_status.status) {
            .STATUS_PROCESSING, .STATUS_QUEUED => {}, // continue the loop
            .STATUS_COMPLETED => break,
            .STATUS_FAILED => {
                return switch (command_status.error_response.?) {
                    .ERROR_KIND_CARRIER_ALREADY_EXISTS => error.CarrierAlreadyExists,
                    .ERROR_KIND_CARRIER_NOT_FOUND => error.CarrierNotFound,
                    .ERROR_KIND_HOMING_FAILED => error.HomingFailed,
                    .ERROR_KIND_INVALID_AXIS => error.InvalidAxis,
                    .ERROR_KIND_INVALID_COMMAND => error.InvalidCommand,
                    .ERROR_KIND_INVALID_PARAMETER => error.InvalidParameter,
                    .ERROR_KIND_INVALID_SYSTEM_STATE => error.InvalidSystemState,
                    else => error.UnexpectedResponse,
                };
            },
            else => return error.UnexpectedResponse,
        }
    }
}

/// Check server response. Return error if the response is a error message.
/// Response that requires memory need to free the memory
fn parseResponse(a: std.mem.Allocator, comptime T: type, msg: []const u8) !T {
    const response: api.mmc_msg.Response =
        try api.mmc_msg.Response.decode(msg, a);

    defer response.deinit();
    std.log.debug("{any}", .{response});
    return switch (response.body.?) {
        inline .command => |command_response| blk: switch (command_response.body.?) {
            inline .command_id => |r| if (@TypeOf(r) == T) break :blk r else unreachable,
            inline .request_error => |r| if (@TypeOf(r) == T) {
                switch (r) {
                    .COMMAND_REQUEST_ERROR_UNSPECIFIED => break :blk error.UnexpectedResponse,
                    .COMMAND_REQUEST_ERROR_INVALID_LINE => break :blk error.InvalidLine,
                    .COMMAND_REQUEST_ERROR_INVALID_AXIS => break :blk error.InvalidAxis,
                    .COMMAND_REQUEST_ERROR_CARRIER_NOT_FOUND => break :blk error.CarrierNotFound,
                    .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED => break :blk error.CCLinkDisconnected,
                    .COMMAND_REQUEST_ERROR_INVALID_ACCELERATION => break :blk error.InvalidAcceleration,
                    .COMMAND_REQUEST_ERROR_INVALID_SPEED => break :blk error.InvalidSpeed,
                    .COMMAND_REQUEST_ERROR_SERVER_RUNNING_OUT_OF_MEMORY => break :blk error.ServerRunningOutOfMemory,
                    .COMMAND_REQUEST_ERROR_MISSING_PARAMETER => break :blk error.MissingParameter,
                    _ => unreachable,
                }
            } else unreachable,
        },
        inline .core => |core_response| switch (core_response.body.?) {
            inline .server => |r| if (@TypeOf(r) == T)
                try r.dupe(allocator)
            else
                unreachable,
            inline .api_version => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .line_config => |r| if (@TypeOf(r) == T)
                try r.dupe(allocator)
            else
                unreachable,
            inline .request_error => |r| switch (r) {
                .CORE_REQUEST_ERROR_UNSPECIFIED => error.UnexpectedResponse,
                .CORE_REQUEST_ERROR_UNKNOWN_REQUEST => error.UnknownRequest,
                _ => unreachable,
            },
        },
        inline .info => |info_response| switch (info_response.body.?) {
            inline .register_x => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .register_y => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .register_wr => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .register_ww => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .command => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .hall_alarm => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .carrier => |r| if (@TypeOf(r) == T) r else unreachable,
            inline .axis => |r| if (@TypeOf(r) == T)
                try r.dupe(allocator)
            else
                unreachable,
            inline .station => |r| if (@TypeOf(r) == T)
                try r.dupe(allocator)
            else
                unreachable,
            inline .request_error => |r| switch (r) {
                .INFO_REQUEST_ERROR_UNSPECIFIED => error.UnexpectedResponse,
                .INFO_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .INFO_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .INFO_REQUEST_ERROR_INVALID_STATION => error.InvalidStation,
                .INFO_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                .INFO_REQUEST_ERROR_CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .INFO_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                _ => unreachable,
            },
        },
    };
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
