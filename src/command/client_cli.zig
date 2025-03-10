const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const mmc = @import("mmc_config");
const network = @import("network");
const CircularBuffer =
    @import("../circular_buffer.zig").CircularBuffer;
const builtin = @import("builtin");

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var line_names: [][]u8 = undefined;
var line_speeds: []u5 = undefined;
var line_accelerations: []u8 = undefined;
const Direction = mmc.Direction;
const Station = mmc.Station;
const SystemState = mmc.SystemState;

var IP_address: []u8 = undefined;
var port: u16 = undefined;

var server: ?network.Socket = null;

pub const Config = struct {
    IP_address: []u8,
    port: u16,
};

pub fn init(c: Config) !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    allocator = arena.allocator();

    try network.init();
    IP_address = try allocator.alloc(u8, c.IP_address.len);
    @memcpy(IP_address, c.IP_address);
    port = c.port;
    std.log.debug("{s}, {}", .{
        IP_address,
        port,
    });
    try command.registry.put("CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file.
        ,
        .execute = &clientConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    try command.registry.put("DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End connection with the mmc server.
        ,
        .execute = &clientDisconnect,
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
        .execute = &clientSetSpeed,
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
        .execute = &clientSetAcceleration,
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
        \\by its name. Acceleration is in meters-per-second-squared.
        ,
        .execute = &clientGetSpeed,
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
        \\referenced by its name. The acceleration is a whole integer number
        \\between 1 and 100, inclusive.
        ,
        .execute = &clientGetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put("PRINT_X", .{
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
    errdefer _ = command.registry.orderedRemove("PRINT_X");
    try command.registry.put("PRINT_Y", .{
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
    errdefer _ = command.registry.orderedRemove("PRINT_Y");
    try command.registry.put("PRINT_WR", .{
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
    errdefer _ = command.registry.orderedRemove("PRINT_WR");
    try command.registry.put("PRINT_WW", .{
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
    errdefer _ = command.registry.orderedRemove("PRINT_WW");
    try command.registry.put("AXIS_CARRIER", .{
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
    try command.registry.put("CARRIER_LOCATION", .{
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
        \\provided line.
        ,
        .execute = &clientCarrierAxis,
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
        .execute = &clientHallStatus,
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
        .execute = &clientAssertHall,
    });
    errdefer _ = command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put("CLEAR_ERRORS", .{
        .name = "CLEAR_ERRORS",
        .short_description = "Clear driver errors of all axis.",
        .long_description =
        \\Clear driver errors of all axis.
        ,
        .execute = &clientClearErrors,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put("RESET_MCL", .{
        .name = "RESET_MCL",
        .short_description = "Reset all MCL registers.",
        .long_description =
        \\Reset all write registers (Y and Ww) on the server.
        ,
        .execute = &clientMclReset,
    });
    errdefer _ = command.registry.orderedRemove("RESET_MCL");
    try command.registry.put("CLEAR_CARRIER_INFO", .{
        .name = "CLEAR_CARRIER_INFO",
        .short_description = "Clear carrier information at all axis.",
        .long_description =
        \\Clear carrier information at all axis.
        ,
        .execute = &clientClearCarrierInfo,
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
        \\Release the servo of a given axis, allowing for free carrier movement.
        \\This command should be run before carriers move within or exit from
        \\the system due to external influence.
        ,
        .execute = &clientAxisReleaseServo,
    });
    errdefer _ = command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put("AUTO_INITIALIZE", .{
        .name = "AUTO_INITIALIZE",
        .short_description = "Initialize all carriers automatically.",
        .long_description =
        \\Isolate all carriers detected in the system automatically and move the
        \\carrier to a free space. Ignore the already initialized carrier. Upon 
        \\completion, all carrier IDs will be printed and its current location.
        ,
        .execute = &clientAutoInitialize,
    });
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
        .execute = &clientCalibrate,
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
        .execute = &clientSetLineZero,
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
        \\Slowly move an uninitialized carrier to separate it from other nearby
        \\carriers. A direction of "backward" or "forward" must be provided. A
        \\carrier ID can be optionally specified to give the isolated carrier an
        \\ID other than the default temporary ID 255, and the next or previous
        \\can also be linked for isolation movement. Linked axis parameter
        \\values must be one of "prev", "next", "left", or "right".
        ,
        .execute = &clientIsolate,
    });
    errdefer _ = command.registry.orderedRemove("ISOLATE");
    // try command.registry.put("RECOVER_CARRIER", .{
    //     .name = "RECOVER_CARRIER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "new carrier ID" },
    //         .{ .name = "use sensor", .resolve = false, .optional = true },
    //     },
    //     .short_description = "Recover an unrecognized carrier on a given axis.",
    //     .long_description =
    //     \\Recover an unrecognized carrier on a given axis. The provided carrier
    //     \\ID must be a positive integer from 1 to 254 inclusive, and must be
    //     \\unique to other recognized carrier IDs. If a sensor is optionally
    //     \\specified for use (valid sensor values include: front, back, left,
    //     \\right), recovery will use the specified hall sensor.
    //     ,
    //     .execute = &mclRecoverCarrier,
    // });
    // errdefer _ = command.registry.orderedRemove("RECOVER_CARRIER");
    try command.registry.put("MOVE_CARRIER_AXIS", .{
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
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number.
        ,
        .execute = &clientCarrierPosMoveLocation,
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
        .execute = &clientCarrierPosMoveDistance,
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
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system. This command moves the
        \\carrier with speed profile feedback.
        ,
        .execute = &clientCarrierSpdMoveAxis,
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
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. This command
        \\moves the carrier with speed profile feedback.
        ,
        .execute = &clientCarrierSpdMoveLocation,
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
        .execute = &clientCarrierSpdMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_CARRIER_DISTANCE");
    try command.registry.put("PUSH_CARRIER_FORWARD", .{
        .name = "PUSH_CARRIER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Push carrier forward by carrier length.",
        .long_description =
        \\Push carrier forward with speed feedback-controlled movement. This
        \\movement targets a distance of the carrier length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the carrier.
        ,
        .execute = &clientCarrierPushForward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_FORWARD");
    try command.registry.put("PUSH_CARRIER_BACKWARD", .{
        .name = "PUSH_CARRIER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Push carrier backward by carrier length.",
        .long_description =
        \\Push carrier backward with speed feedback-controlled movement. This
        \\movement targets a distance of the carrier length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the carrier.
        ,
        .execute = &clientCarrierPushBackward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    try command.registry.put("PULL_CARRIER_FORWARD", .{
        .name = "PULL_CARRIER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
        },
        .short_description = "Pull incoming carrier forward at axis.",
        .long_description =
        \\Pull incoming carrier forward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_CARRIER" command.
        \\The pulled carrier's ID must also be provided.
        ,
        .execute = &clientCarrierPullForward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    try command.registry.put("PULL_CARRIER_BACKWARD", .{
        .name = "PULL_CARRIER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
        },
        .short_description = "Pull incoming carrier backward at axis.",
        .long_description =
        \\Pull incoming carrier backward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_CARRIER" command.
        \\The pulled carrier's ID must also be provided.
        ,
        .execute = &clientCarrierPullBackward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
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
        .execute = &clientCarrierStopPull,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_CARRIER");
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
}

pub fn waitErrorMessage() !void {
    var buffer: [128]u8 = undefined;
    const stdout = std.io.getStdOut().writer();
    while (server) |s| {
        const fd: std.posix.pollfd = .{
            .fd = s.internal,
            .events = switch (builtin.os.tag) {
                .linux => std.os.linux.POLL.RDNORM,
                .windows => std.os.windows.ws2_32.POLL.RDNORM,
                else => unreachable,
            },
            .revents = 0,
        };
        var poll_fd: [1]std.posix.pollfd = .{fd};
        const status = std.posix.poll(&poll_fd, 0) catch {
            std.log.debug("poll failed", .{});
            break;
        };
        // Avoid blocking read from clients
        if (status == 0) continue;

        const msg_size = s.receive(&buffer) catch break;
        if (msg_size == 0) break;
        try stdout.print("{s}\n", .{buffer[0..msg_size]});
    }
}

pub fn clientConnect(_: [][]const u8) !void {
    std.log.debug("Trying to connect to {s}", .{
        IP_address,
    });
    std.log.debug("Trying to connect to port {}", .{
        port,
    });
    server = try network.connectToHost(
        allocator,
        IP_address,
        port,
        .tcp,
    );
    if (server) |s| {
        const server_thread = std.Thread.spawn(
            .{},
            waitErrorMessage,
            .{},
        ) catch |e| {
            s.close();
            return e;
        };
        server_thread.detach();
        std.log.info(
            "Connected to {}",
            .{try s.getRemoteEndPoint()},
        );
        std.log.info("Receiving line information...", .{});
        var buffer: [1024]u8 = undefined;
        _ = try s.receive(&buffer);
        std.log.debug("{s}", .{buffer});
        var tokenizer = std.mem.tokenizeSequence(
            u8,
            &buffer,
            ",",
        );
        const line_numbers = try std.fmt.parseInt(
            usize,
            tokenizer.next().?,
            0,
        );
        line_names = try allocator.alloc([]u8, line_numbers);
        var lines = try allocator.alloc(
            mcl.Config.Line,
            line_numbers,
        );
        defer allocator.free(lines);
        errdefer allocator.free(lines);
        for (0..line_numbers) |li| {
            if (tokenizer.next()) |token| {
                var line_description = std.mem.tokenizeSequence(
                    u8,
                    token,
                    ":",
                );
                const line_name =
                    line_description.next() orelse return error.LineNameNotReceived;
                line_names[li] = try allocator.alloc(u8, line_name.len);
                @memcpy(line_names[li], line_name);
                lines[li].axes = try std.fmt.parseInt(
                    mcl.Axis.Id.Line,
                    line_description.next() orelse return error.AxisNumberNotReceived,
                    0,
                );
                const range_len = try std.fmt.parseInt(
                    usize,
                    line_description.next() orelse return error.RangeNumberNotReceived,
                    0,
                );
                lines[li].ranges = try allocator.alloc(
                    mcl.Config.Line.Range,
                    range_len,
                );
                for (0..range_len) |ri| {
                    lines[li].ranges[ri].channel = std.meta.stringToEnum(
                        mcl.cc_link.Channel,
                        line_description.next() orelse return error.ChannelInfoNotReceived,
                    ) orelse return error.ChannelUnknown;
                    lines[li].ranges[ri].start = try std.fmt.parseInt(
                        mcl.cc_link.Id,
                        line_description.next() orelse return error.StartInfoDataNotReceived,
                        0,
                    );
                    lines[li].ranges[ri].end = try std.fmt.parseInt(
                        mcl.cc_link.Id,
                        line_description.next() orelse return error.EndInfoNotReceived,
                        0,
                    );
                }
                if (line_description.peek() != null) {
                    std.log.debug(
                        "Remaining unexpected line description: {s}",
                        .{line_description.rest()},
                    );
                    return error.UnexpectedDataReceived;
                }
            }
        }
        try mcl.Config.validate(.{ .lines = lines });
        try mcl.init(allocator, .{ .lines = lines });
        line_speeds = try allocator.alloc(u5, line_numbers);
        line_accelerations = try allocator.alloc(u8, line_numbers);
        for (0..line_numbers) |i| {
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

pub fn clientDisconnect(_: [][]const u8) !void {
    if (server) |s| {
        s.close();
        server = null;
        for (line_names) |name| {
            allocator.free(name);
        }
        allocator.free(line_names);
        allocator.free(line_accelerations);
        allocator.free(line_speeds);
        std.log.info("Disconnected from server", .{});
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

fn clientStationX(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_x;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = @intCast(axis_idx),
    };
    if (server) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("msg_size: {}", .{msg_size});
        std.log.debug("data: {any}", .{buffer[0..msg_size]});
        std.log.debug("x size: {}", .{@sizeOf(mcl.registers.X)});
        if (msg_size != @sizeOf(mcl.registers.X)) {
            std.log.err("{s}", .{buffer[0..msg_size]});
        } else {
            const x = std.mem.bytesToValue(
                mcl.registers.X,
                buffer[0..msg_size],
            );
            std.log.info("{}", .{x});
        }
    } else return error.ServerNotConnected;
}

fn clientStationY(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_y;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = @intCast(axis_idx),
    };
    if (server) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        if (msg_size != @sizeOf(mcl.registers.Y)) {
            std.log.err("{s}", .{buffer[0..msg_size]});
        } else {
            const y = std.mem.bytesToValue(
                mcl.registers.Y,
                buffer[0..msg_size],
            );
            std.log.info("{}", .{y});
        }
    } else return error.ServerNotConnected;
}

fn clientStationWr(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_wr;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = @intCast(axis_idx),
    };
    if (server) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        if (msg_size != @sizeOf(mcl.registers.Wr)) {
            std.log.err("{s}", .{buffer[0..msg_size]});
        } else {
            const wr = std.mem.bytesToValue(
                mcl.registers.Wr,
                buffer[0..msg_size],
            );
            std.log.info("{}", .{wr});
        }
    } else return error.ServerNotConnected;
}

fn clientStationWw(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_ww;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = @intCast(axis_idx),
    };
    if (server) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        if (msg_size != @sizeOf(mcl.registers.Ww)) {
            std.log.err("{s}", .{buffer[0..msg_size]});
        } else {
            const ww = std.mem.bytesToValue(
                mcl.registers.Ww,
                buffer[0..msg_size],
            );
            std.log.info("{}", .{ww});
        }
    } else return error.ServerNotConnected;
}

fn clientAxisCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    if (server) |s| {
        var buffer: [1_000_000]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        var msg_bit_size: usize = 0;
        const num_of_carriers = std.mem.readPackedInt(
            u10,
            buffer[0..msg_size],
            0,
            .little,
        );
        msg_bit_size += @bitSizeOf(u10);
        const IntType =
            @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
        var detected_carriers: usize = 0;
        while (detected_carriers < num_of_carriers) {
            const carrier_int = std.mem.readPackedInt(
                IntType,
                &buffer,
                msg_bit_size,
                .little,
            );
            detected_carriers += 1;
            msg_bit_size += @bitSizeOf(IntType);
            const carrier: SystemState.Carrier = @bitCast(carrier_int);
            std.log.debug(
                "carrier_id: {}\n first_axis: {}\n second_axis: {}\n location: {}",
                .{
                    carrier.carrier_id,
                    carrier.axis_ids.first,
                    carrier.axis_ids.second,
                    carrier.location,
                },
            );
            if (carrier.line_id == line_idx + 1 and
                carrier.carrier_id != 0 and
                (carrier.axis_ids.first == axis_id or
                    carrier.axis_ids.second == axis_id))
            {
                std.log.info(
                    "Carrier {d} on axis {d}.\n",
                    .{ carrier.carrier_id, axis_id },
                );
                return;
            }
        }
        std.log.info(
            "No carrier recognized on axis {d}.\n",
            .{axis_id},
        );
    } else return error.ServerNotConnected;
}

fn clientAutoInitialize(_: [][]const u8) !void {
    var socket: network.Socket = undefined;
    if (server) |s| {
        socket = s;
    } else return error.ServerNotConnected;
    var total_axes: usize = 0;
    // Track the starting index of each line when the lines are cascaded
    var starting_axis_indices = try allocator.alloc(
        usize,
        mcl.lines.len,
    );
    for (mcl.lines, 0..) |line, idx| {
        starting_axis_indices[idx] = total_axes;
        total_axes += line.axes.len;
    }
    var hall_sensors: []bool = undefined;
    hall_sensors = try allocator.alloc(bool, total_axes * 2);
    // 1st: Map hall sensor status to `hall_sensors` variable
    hall_sensors = try mapHallSensors(
        hall_sensors,
        starting_axis_indices,
        socket,
    );
    // 2nd: iterate over `hall_sensors` to determine clusters
    // -> clusters: range of index (start and end)
    var enabled_sensor_count: usize = 0;
    var disabled_sensor_count: usize = 0;
    const SensorChain = enum { Enabled, Disabled };
    var chain: SensorChain = .Disabled;
    const Cluster = struct {
        start: usize,
        end: usize,
        direction: Direction,
        // the isolate algorithm requires which hall index is being used
        current_hall_index: usize,
        initialized_carriers: usize,
        carrier_ids: [1024]u10,
    };
    var clusters =
        try CircularBuffer(Cluster).initCapacity(allocator, 1024);
    var start_index: usize = 0; // starting axis when a cluster is detected
    var end_index: usize = 0;
    defer clusters.deinit();
    errdefer clusters.deinit();
    std.log.debug("{any}", .{hall_sensors});
    for (hall_sensors, 0..) |alarm_state, idx| {
        std.log.debug(
            "start_idx: {}, disabled: {}, enabled: {}, clusters: {}",
            .{
                start_index,
                disabled_sensor_count,
                enabled_sensor_count,
                clusters.items(),
            },
        );
        if (chain == .Disabled) {
            if (alarm_state == true) {
                chain = .Enabled;
                if (enabled_sensor_count != 0) {
                    enabled_sensor_count += disabled_sensor_count;
                }
                enabled_sensor_count += 1;
                // disabled to zero is required for looking the cluster ending
                disabled_sensor_count = 0;
            } else {
                disabled_sensor_count += 1;
                // when looking for the beginning of cluster
                if (disabled_sensor_count == 4 and enabled_sensor_count == 0) {
                    start_index += 1;
                    disabled_sensor_count -= 1;
                }
                // when looking for the ending of cluster
                if (enabled_sensor_count != 0 and disabled_sensor_count == 3) {
                    // check if the cluster is feasible for backward cluster
                    // backward is possible if three hall sensor is inactive
                    end_index = idx;
                    var backward_cluster = true;
                    std.log.debug("checking backward cluster...", .{});
                    for (start_index..start_index + 3) |i| {
                        std.log.debug("hall {}: {}", .{ i, hall_sensors[i] });
                        if (hall_sensors[i]) backward_cluster = false;
                    }
                    std.log.debug("backward: {}", .{backward_cluster});
                    var forward_cluster = true;
                    std.log.debug("checking forward cluster...", .{});
                    for (end_index - 2..end_index + 1) |i| {
                        std.log.debug("hall {}: {}", .{ i, hall_sensors[i] });
                        if (hall_sensors[i]) forward_cluster = false;
                    }
                    std.log.debug(
                        "backward: {}, forward: {}",
                        .{ backward_cluster, forward_cluster },
                    );
                    if (forward_cluster and backward_cluster and enabled_sensor_count <= 2) {
                        end_index = idx - 3;
                        std.log.debug(
                            "writing for multidirection cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .backward,
                            .current_hall_index = start_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                        start_index = end_index + 1;
                        disabled_sensor_count = 3;
                        enabled_sensor_count = 0;
                        end_index = 0;
                        continue;
                    } // When a cluster can isolate forward and backward
                    else if (forward_cluster and
                        backward_cluster and
                        enabled_sensor_count > 2)
                    {
                        std.log.debug(
                            "writing for multidirection cluster, start: {}, end: {}",
                            .{ start_index, end_index },
                        );
                        const mean_idx: f16 =
                            (@as(f16, @floatFromInt(end_index)) +
                                @as(f16, @floatFromInt(start_index))) / 2;
                        std.log.debug("mean_idx: {}", .{mean_idx});
                        if (@mod(mean_idx, 2) == 0) {
                            try clusters.writeItem(.{
                                .start = start_index,
                                .end = @intFromFloat(mean_idx),
                                .direction = .backward,
                                .current_hall_index = start_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                            try clusters.writeItem(.{
                                .start = @intFromFloat(mean_idx + 2),
                                .end = end_index,
                                .direction = .forward,
                                .current_hall_index = end_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                        } else {
                            try clusters.writeItem(.{
                                .start = start_index,
                                .end = @intFromFloat(mean_idx - 0.5),
                                .direction = .backward,
                                .current_hall_index = start_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                            try clusters.writeItem(.{
                                .start = @intFromFloat(mean_idx + 2),
                                .end = end_index,
                                .direction = .forward,
                                .current_hall_index = end_index,
                                .initialized_carriers = 0,
                                .carrier_ids = .{0} ** 1024,
                            });
                        }
                    } else if (forward_cluster and !backward_cluster) {
                        while (hall_sensors[start_index] == false) {
                            start_index += 1;
                        }
                        std.log.debug(
                            "writing for forward cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .forward,
                            .current_hall_index = end_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                    } else if (!forward_cluster and backward_cluster) {
                        while (hall_sensors[end_index] == false) {
                            end_index -= 1;
                        }
                        std.log.debug(
                            "writing for backward cluster",
                            .{},
                        );
                        try clusters.writeItem(.{
                            .start = start_index,
                            .end = end_index,
                            .direction = .backward,
                            .current_hall_index = start_index,
                            .initialized_carriers = 0,
                            .carrier_ids = .{0} ** 1024,
                        });
                    }
                    disabled_sensor_count = 0;
                    enabled_sensor_count = 0;
                    start_index = idx + 1;
                    end_index = 0;
                }
            }
            if (idx == hall_sensors.len - 1 and enabled_sensor_count != 0) {
                end_index = idx;
                std.log.debug(
                    "writing for the end of system cluster",
                    .{},
                );
                try clusters.writeItem(.{
                    .start = start_index,
                    .end = end_index,
                    .direction = .forward,
                    .current_hall_index = start_index,
                    .initialized_carriers = 0,
                    .carrier_ids = .{0} ** 1024,
                });
            }
        } else {
            if (alarm_state == false) {
                chain = .Disabled;
                disabled_sensor_count += 1;
            } else {
                enabled_sensor_count += 1;
                // when the final hall sensor is enabled, create a backward cluster
            }
            if (idx == hall_sensors.len - 1) {
                end_index = idx;
                std.log.debug(
                    "writing for the end of system cluster",
                    .{},
                );
                try clusters.writeItem(.{
                    .start = start_index,
                    .end = end_index,
                    .direction = .backward,
                    .current_hall_index = start_index,
                    .initialized_carriers = 0,
                    .carrier_ids = .{0} ** 1024,
                });
            }
        }
    }
    for (0..clusters.items()) |i| {
        const cluster = clusters.readItem().?;
        std.log.info(
            "cluster {}, start: {}, end: {}, direction: {}",
            .{ i + 1, cluster.start, cluster.end, cluster.direction },
        );
        try clusters.writeItem(cluster);
    }
    std.log.debug("\n\n", .{});
    // 3rd send command to the server based on the cluster
    var carrier_id: usize = 0;
    var initialized_carrier_id: usize = 0;
    while (clusters.readItem()) |cluster| {
        try command.checkCommandInterrupt();
        // if carrier detected in the current axis in interest, then move it
        // to the middle of axis. If there is any axis left in the cluster,
        // write to back to the clusters.
        const current_axis = cluster.current_hall_index / 2;
        var aux_axis: usize = undefined;
        if (cluster.direction == .backward and current_axis != 0) {
            aux_axis = current_axis - 1;
        } else if (cluster.direction == .forward and
            current_axis != total_axes - 1)
        {
            aux_axis = current_axis + 1;
        }
        std.log.debug(
            "cluster start: {}, cluster end: {}, current hall: {}",
            .{ cluster.start, cluster.end, cluster.current_hall_index },
        );
        std.log.debug(
            "initialized id: {}, current carrier id: {}",
            .{ initialized_carrier_id, carrier_id },
        );
        if (try checkCarrierExistence(current_axis, aux_axis, socket)) |carrier_info| {
            const detected_carrier_id = carrier_info.@"0";
            var is_carrier_member = false;
            for (cluster.carrier_ids) |id| {
                if (id == @as(u10, @truncate(detected_carrier_id))) {
                    is_carrier_member = true;
                    break;
                }
            }
            if (is_carrier_member == false) {
                try clusters.writeItem(cluster);
                continue;
            }
            if (detected_carrier_id > initialized_carrier_id) {
                initialized_carrier_id = detected_carrier_id;
            }
            const axis_idx = carrier_info.@"1";
            var line_idx: usize = undefined;
            for (starting_axis_indices, 0..) |starting_axis_index, idx| {
                if (axis_idx >= starting_axis_index) {
                    line_idx = idx;
                    break;
                }
            }
            std.log.debug(
                "cluster start: {}, cluster end: {}",
                .{ cluster.start, cluster.end },
            );
            const start_axis_idx = if (cluster.start % 2 == 0)
                cluster.start / 2
            else
                cluster.start / 2 + 1;
            const end_axis_idx = if (cluster.end % 2 == 0)
                cluster.end / 2 - 1
            else
                cluster.end / 2;
            const target_axis = if (cluster.direction == .backward)
                start_axis_idx
            else
                end_axis_idx;
            var param = std.mem.zeroes(mmc.ParamType(.set_command));
            param.command_code = .PositionMoveCarrierAxis;
            param.line_idx = @truncate(line_idx);
            param.axis_idx = @truncate(target_axis);
            param.carrier_id = @truncate(detected_carrier_id);
            param.speed = line_speeds[line_idx];
            param.acceleration = line_accelerations[line_idx];
            try sendMessage(
                .set_command,
                param,
                socket,
            );
            if ((cluster.current_hall_index < cluster.end - 1 and
                cluster.direction == .backward) or
                (cluster.current_hall_index > cluster.start + 1 and
                    cluster.direction == .forward))
            {
                try clusters.writeItem(.{
                    .current_hall_index = if (cluster.direction == .backward)
                        cluster.current_hall_index + 2
                    else
                        cluster.current_hall_index - 2,
                    .direction = cluster.direction,
                    .end = if (cluster.direction == .forward)
                        target_axis * 2 - 1
                    else
                        cluster.end,
                    .start = if (cluster.direction == .backward)
                        (target_axis + 1) * 2
                    else
                        cluster.start,
                    .carrier_ids = cluster.carrier_ids,
                    .initialized_carriers = cluster.initialized_carriers,
                });
            }
        } else if (initialized_carrier_id == carrier_id) {
            // Scan the hall sensor from the beginning of cluster (depending on
            // the direction).
            if (try assertNoProgressing(
                cluster.current_hall_index / 2,
                socket,
            ) == false) {
                try clusters.writeItem(cluster);
                std.log.debug("\n\n", .{});
                continue;
            }
            if (try checkHallStatus(
                cluster.current_hall_index,
                socket,
            ) == false) {
                try clusters.writeItem(.{
                    .current_hall_index = if (cluster.direction == .backward)
                        cluster.current_hall_index + 1
                    else
                        cluster.current_hall_index - 1,
                    .direction = cluster.direction,
                    .end = cluster.end,
                    .start = cluster.start,
                    .carrier_ids = cluster.carrier_ids,
                    .initialized_carriers = cluster.initialized_carriers,
                });
                std.log.debug("\n\n", .{});
                continue;
            }
            carrier_id += 1;
            const direction = cluster.direction;

            const axis_idx: usize = cluster.current_hall_index / 2;
            var link_axis: Direction = .no_direction;
            var line_idx: usize = undefined;

            if (cluster.current_hall_index % 2 == 1 and
                direction == .backward and
                cluster.end - cluster.current_hall_index > 0)
            {
                link_axis = .forward;
            } else if (cluster.current_hall_index % 2 == 0 and
                direction == .forward and
                cluster.current_hall_index - cluster.start > 0)
            {
                link_axis = .backward;
            }
            for (starting_axis_indices, 0..) |starting_axis_index, idx| {
                if (axis_idx >= starting_axis_index) {
                    line_idx = idx;
                    break;
                }
            }

            var param = std.mem.zeroes(mmc.ParamType(.set_command));
            param.command_code = if (direction == .forward)
                .IsolateForward
            else
                .IsolateBackward;
            param.line_idx = @truncate(line_idx);
            param.axis_idx = @truncate(axis_idx);
            param.carrier_id = @truncate(carrier_id);
            param.link_axis = link_axis;
            try sendMessage(
                .set_command,
                param,
                socket,
            );
            var new_cluster = cluster;
            new_cluster.initialized_carriers += 1;
            new_cluster.carrier_ids[new_cluster.initialized_carriers] =
                @truncate(carrier_id);
            try clusters.writeItem(new_cluster);
        } else {
            try clusters.writeItem(cluster);
        }
        std.log.debug("\n\n", .{});
    }
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
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .release_axis_servo;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = axis_idx,
    };
    if (server) |s| {
        try sendMessage(kind, param, s);
    } else return error.ServerNotConnected;
}

fn clientClearErrors(_: [][]const u8) !void {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .clear_errors;
    const param = {};
    if (server) |s| {
        try sendMessage(kind, param, s);
    } else return error.ServerNotConnected;
}

fn clientClearCarrierInfo(_: [][]const u8) !void {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .clear_carrier_info;
    const param = {};
    if (server) |s| {
        try sendMessage(kind, param, s);
    } else return error.ServerNotConnected;
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    if (server) |s| {
        var buffer: [1_000_000]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        var msg_bit_size: usize = 0;
        const num_of_carriers = std.mem.readPackedInt(
            u10,
            buffer[0..msg_size],
            0,
            .little,
        );
        msg_bit_size += @bitSizeOf(u10);
        const IntType =
            @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
        var detected_carriers: usize = 0;
        while (detected_carriers < num_of_carriers) {
            const carrier_int = std.mem.readPackedInt(
                IntType,
                &buffer,
                msg_bit_size,
                .little,
            );
            detected_carriers += 1;
            msg_bit_size += @bitSizeOf(IntType);
            const carrier: SystemState.Carrier = @bitCast(carrier_int);
            std.log.debug(
                "carrier_id: {}\n first_axis: {}\n second_axis: {}\n location: {}",
                .{
                    carrier.carrier_id,
                    carrier.axis_ids.first,
                    carrier.axis_ids.second,
                    carrier.location,
                },
            );
            if (carrier.line_id == line_idx + 1 and
                carrier.carrier_id == carrier_id)
            {
                std.log.info(
                    "Carrier {d} location: {d} mm",
                    .{ carrier.carrier_id, carrier.location },
                );
                return;
            }
        }
        std.log.err(
            "Carrier not found",
            .{},
        );
    } else return error.ServerNotConnected;
}

fn clientCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    if (server) |s| {
        var buffer: [1_000_000]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        var msg_bit_size: usize = 0;
        const num_of_carriers = std.mem.readPackedInt(
            u10,
            buffer[0..msg_size],
            0,
            .little,
        );
        msg_bit_size += @bitSizeOf(u10);
        const IntType =
            @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
        var detected_carriers: usize = 0;
        while (detected_carriers < num_of_carriers) {
            const carrier_int = std.mem.readPackedInt(
                IntType,
                &buffer,
                msg_bit_size,
                .little,
            );
            detected_carriers += 1;
            msg_bit_size += @bitSizeOf(IntType);
            const carrier: SystemState.Carrier = @bitCast(carrier_int);
            std.log.debug(
                "carrier_id: {}\n first_axis: {}\n second_axis: {}\n location: {}",
                .{
                    carrier.carrier_id,
                    carrier.axis_ids.first,
                    carrier.axis_ids.second,
                    carrier.location,
                },
            );
            if (carrier.line_id == line_idx + 1 and
                carrier.carrier_id == carrier_id)
            {
                std.log.info(
                    "Carrier {d} axis: {}",
                    .{ carrier.carrier_id, carrier.axis_ids.first },
                );
                if (carrier.axis_ids.second == 0) return;
                std.log.info(
                    "Carrier {d} axis: {}",
                    .{ carrier.carrier_id, carrier.axis_ids.second },
                );
                return;
            }
        }
        std.log.err(
            "Carrier not found",
            .{},
        );
    } else return error.ServerNotConnected;
}

fn clientHallStatus(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    var axis_id: mcl.Axis.Id.Line = 0;
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (params[1].len > 0) {
        axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
    }
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    if (server) |s| {
        var buffer: [1_000_000]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        var msg_bit_size: usize = 0;
        const num_of_active_axis = std.mem.readPackedInt(
            mcl.Axis.Id.Line,
            buffer[0..msg_size],
            0,
            .little,
        );
        msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
        const IntType =
            @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
        var detected_active_axis: usize = 0;
        while (detected_active_axis < num_of_active_axis) {
            const hall_sensor_int = std.mem.readPackedInt(
                IntType,
                &buffer,
                msg_bit_size,
                .little,
            );
            detected_active_axis += 1;
            msg_bit_size += @bitSizeOf(IntType);
            const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
            std.log.debug(
                "line_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
                .{
                    hall_sensor.line_id,
                    hall_sensor.axis_id,
                    hall_sensor.hall_states.front,
                    hall_sensor.hall_states.back,
                },
            );
            if (axis_id == 0) {
                std.log.info(
                    "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                    .{
                        hall_sensor.axis_id,
                        if (hall_sensor.hall_states.front) "ON" else "OFF",
                        if (hall_sensor.hall_states.back) "ON" else "OFF",
                    },
                );
            } else {
                if (hall_sensor.axis_id == axis_id) {
                    std.log.info(
                        "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                        .{
                            hall_sensor.axis_id,
                            if (hall_sensor.hall_states.front) "ON" else "OFF",
                            if (hall_sensor.hall_states.back) "ON" else "OFF",
                        },
                    );
                }
            }
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

    var alarm_on: bool = true;
    if (params[3].len > 0) {
        if (std.ascii.eqlIgnoreCase("off", params[3])) {
            alarm_on = false;
        } else if (std.ascii.eqlIgnoreCase("on", params[3])) {
            alarm_on = true;
        } else return error.InvalidHallAlarmState;
    }
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    if (server) |s| {
        var buffer: [1_000_000]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        var msg_bit_size: usize = 0;
        const num_of_active_axis = std.mem.readPackedInt(
            mcl.Axis.Id.Line,
            buffer[0..msg_size],
            0,
            .little,
        );
        msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
        const IntType =
            @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
        var detected_active_axis: usize = 0;
        while (detected_active_axis < num_of_active_axis) {
            const hall_sensor_int = std.mem.readPackedInt(
                IntType,
                &buffer,
                msg_bit_size,
                .little,
            );
            detected_active_axis += 1;
            msg_bit_size += @bitSizeOf(IntType);
            const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
            std.log.debug(
                "line_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
                .{
                    hall_sensor.line_id,
                    hall_sensor.axis_id,
                    hall_sensor.hall_states.front,
                    hall_sensor.hall_states.back,
                },
            );
            if (hall_sensor.axis_id == axis_id and
                hall_sensor.line_id == line_idx + 1)
            {
                switch (side) {
                    .backward => {
                        if (hall_sensor.hall_states.back != alarm_on) {
                            return error.UnexpectedHallAlarm;
                        }
                    },
                    .forward => {
                        if (hall_sensor.hall_states.front != alarm_on) {
                            return error.UnexpectedHallAlarm;
                        }
                    },
                }
            }
        }
    } else return error.ServerNotConnected;
}

fn clientMclReset(_: [][]const u8) !void {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .reset_mcl;
    const param = {};
    if (server) |s| {
        try sendMessage(kind, param, s);
    } else return error.ServerNotConnected;
}

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .Calibration;
    param.line_idx = @truncate(line_idx);
    if (server) |s| {
        try sendMessage(.set_command, param, s);
    } else return error.ServerNotConnected;
}

fn clientSetLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SetLineZero;
    param.line_idx = @truncate(line_idx);

    if (server) |s| {
        try sendMessage(.set_command, param, s);
    } else return error.ServerNotConnected;
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
    const link_axis: mmc.Direction = link: {
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

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = if (dir == .forward)
        .IsolateForward
    else
        .IsolateBackward;
    param.line_idx = @truncate(line_idx);
    param.axis_idx = axis_index;
    param.carrier_id = carrier_id;
    param.link_axis = link_axis;
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
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
    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PositionMoveCarrierAxis;
    param.line_idx = @truncate(line_idx);
    param.axis_idx = axis_index;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PositionMoveCarrierLocation;
    param.line_idx = @truncate(line_idx);
    param.location_distance = location;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
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

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PositionMoveCarrierDistance;
    param.line_idx = @truncate(line_idx);
    param.location_distance = distance;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
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

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SpeedMoveCarrierAxis;
    param.line_idx = @truncate(line_idx);
    param.axis_idx = axis_index;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SpeedMoveCarrierLocation;
    param.line_idx = @truncate(line_idx);
    param.location_distance = location;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
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

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SpeedMoveCarrierDistance;
    param.line_idx = @truncate(line_idx);
    param.location_distance = distance;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPushForward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PushAxisCarrierForward;
    param.line_idx = @truncate(line_idx);
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPushBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PushAxisCarrierBackward;
    param.line_idx = @truncate(line_idx);
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPullForward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PullAxisCarrierForward;
    param.line_idx = @truncate(line_idx);
    param.carrier_id = carrier_id;
    param.axis_idx = axis_index;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPullBackward(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const carrier_id = try std.fmt.parseInt(u10, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PullAxisCarrierBackward;
    param.line_idx = @truncate(line_idx);
    param.carrier_id = carrier_id;
    param.axis_idx = axis_index;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    if (server) |s| try sendMessage(
        .set_command,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;
    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .stop_pull_carrier;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = axis_index,
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
        mmc.Param,
    ).@"union".tag_type.?,
    param: mmc.ParamType(kind),
    to_server: network.Socket,
) !void {
    const msg: mmc.Message(kind) =
        .{
            .kind = @intFromEnum(kind),
            ._unused_kind = 0,
            .param = param,
            ._rest_param = 0,
        };
    try to_server.writer().writeStruct(msg);
    if (kind == .set_command) {
        if (param.command_code == .IsolateForward) {
            std.log.debug(
                "Sent command {s}\nline: {s}\naxis id: {}\ncarrier_id: {}\ndirection: {s}\nlink_axis: {s}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.axis_idx + 1,
                    param.carrier_id,
                    "forward",
                    @tagName(param.link_axis),
                },
            );
        } else if (param.command_code == .IsolateBackward) {
            std.log.debug(
                "Sent command {s}\nline: {s}\naxis id: {}\ncarrier_id: {}\ndirection: {s}\nlink_axis: {s}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.axis_idx + 1,
                    param.carrier_id,
                    "backward",
                    @tagName(param.link_axis),
                },
            );
        } else if (param.command_code == .PositionMoveCarrierAxis) {
            std.log.debug(
                "Sent command{s}\nline: {s}\ncarrier_id: {}\ndestination: {}\n",
                .{
                    @tagName(param.command_code),
                    line_names[param.line_idx],
                    param.carrier_id,
                    param.axis_idx + 1,
                },
            );
        }
    }
}

fn getFreeAxisIndex(
    start_hall_idx: usize,
    end_hall_idx: usize,
    direction: Direction,
    socket: network.Socket,
) !usize {
    const start_axis_idx = if (start_hall_idx % 2 == 0)
        start_hall_idx / 2
    else
        start_hall_idx / 2 + 1;
    const end_axis_idx = if (end_hall_idx % 2 == 0)
        end_hall_idx / 2 - 1
    else
        end_hall_idx / 2;
    var result = if (direction == .backward) start_axis_idx else end_axis_idx;
    std.log.debug(
        "result: {}, direction: {s}, start: {}, end: {}",
        .{ result, @tagName(direction), start_axis_idx, end_axis_idx },
    );
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        if (hall_sensor.axis_id - 1 == result) {
            if (direction == .forward and hall_sensor.hall_states.front) {
                std.log.debug(
                    "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
                    .{ direction == .forward, hall_sensor.hall_states.front },
                );
                result -= 1;
            } else if (direction == .backward and hall_sensor.hall_states.back) {
                std.log.debug(
                    "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
                    .{ direction == .forward, hall_sensor.hall_states.front },
                );
                result += 1;
            }
        }
        std.log.debug("result: {}", .{result});
    }
    return result;
}

fn checkHallStatus(hall_index: usize, socket: network.Socket) !bool {
    const hall_axis_id = hall_index / 2 + 1;
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        if (hall_axis_id == hall_sensor.axis_id) {
            if ((hall_index % 2 == 0 and hall_sensor.hall_states.back) or
                (hall_index % 2 != 0 and hall_sensor.hall_states.front))
            {
                return true;
            }
        }
    }
    return false;
}

/// check if there is a carrier at the specified axis
fn checkCarrierExistence(
    main_idx: usize,
    aux_idx: usize,
    socket: network.Socket,
) !?struct { usize, usize } {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_carriers = std.mem.readPackedInt(
        u10,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(u10);
    const IntType =
        @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
    var detected_carriers: usize = 0;
    while (detected_carriers < num_of_carriers) {
        try command.checkCommandInterrupt();
        const carrier_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_carriers += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const carrier: SystemState.Carrier = @bitCast(carrier_int);
        std.log.debug(
            "carrier_id: {}-first_axis: {}-second_axis: {}-location: {}",
            .{
                carrier.carrier_id,
                carrier.axis_ids.first,
                carrier.axis_ids.second,
                carrier.location,
            },
        );
        if ((carrier.axis_ids.first == main_idx + 1 or
            carrier.axis_ids.second == main_idx + 1) and
            (carrier.state == .BackwardIsolationCompleted or
                carrier.state == .ForwardIsolationCompleted))
        {
            return .{ carrier.carrier_id, main_idx };
        }
        if ((carrier.axis_ids.first == aux_idx + 1 or
            carrier.axis_ids.second == aux_idx + 1) and
            (carrier.state == .BackwardIsolationCompleted or
                carrier.state == .ForwardIsolationCompleted))
        {
            return .{ carrier.carrier_id, aux_idx };
        }
    }
    return null;
}

/// Map the hall sensor status from the server to `hall_sensors` variable
fn mapHallSensors(
    hall_sensors: []bool,
    starting_axis_indices: []usize,
    socket: network.Socket,
) ![]bool {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Hall,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_active_axis = std.mem.readPackedInt(
        mcl.Axis.Id.Line,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(mcl.Axis.Id.Line);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    var detected_active_axis: usize = 0;
    while (detected_active_axis < num_of_active_axis) {
        try command.checkCommandInterrupt();
        const hall_sensor_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_active_axis += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const hall_sensor: SystemState.Hall = @bitCast(hall_sensor_int);
        std.log.debug(
            "Hall status: \nline_id: {}\n axis_id: {}\n front hall sensor: {}\n back hall sensor: {}",
            .{
                hall_sensor.line_id,
                hall_sensor.axis_id,
                hall_sensor.hall_states.front,
                hall_sensor.hall_states.back,
            },
        );
        const back_idx = starting_axis_indices[hall_sensor.line_id - 1] +
            (hall_sensor.axis_id - 1) * 2;
        const front_idx = starting_axis_indices[hall_sensor.line_id - 1] +
            (hall_sensor.axis_id - 1) * 2 + 1;
        hall_sensors[back_idx] = hall_sensor.hall_states.back;
        hall_sensors[front_idx] = hall_sensor.hall_states.front;
    }
    return hall_sensors;
}

/// assert that current axis does not have a moving carrier
fn assertNoProgressing(axis_idx: usize, socket: network.Socket) !bool {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_status;
    const param: mmc.ParamType(kind) = .{
        .kind = .Carrier,
    };
    var buffer: [1_000_000]u8 = undefined;
    try sendMessage(kind, param, socket);
    const msg_size = try socket.receive(&buffer);
    var msg_bit_size: usize = 0;
    const num_of_carriers = std.mem.readPackedInt(
        u10,
        buffer[0..msg_size],
        0,
        .little,
    );
    msg_bit_size += @bitSizeOf(u10);
    const IntType =
        @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
    var detected_carriers: usize = 0;
    while (detected_carriers < num_of_carriers) {
        try command.checkCommandInterrupt();
        const carrier_int = std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_bit_size,
            .little,
        );
        detected_carriers += 1;
        msg_bit_size += @bitSizeOf(IntType);
        const carrier: SystemState.Carrier = @bitCast(carrier_int);
        std.log.debug(
            "carrier_id: {}-first_axis: {}-second_axis: {}-location: {}",
            .{
                carrier.carrier_id,
                carrier.axis_ids.first,
                carrier.axis_ids.second,
                carrier.location,
            },
        );
        if ((carrier.axis_ids.first == axis_idx + 1 or
            carrier.axis_ids.second == axis_idx + 1) and
            (carrier.state == .ForwardIsolationProgressing or
                carrier.state == .BackwardIsolationProgressing))
        {
            return false;
        }
    }
    return true;
}
