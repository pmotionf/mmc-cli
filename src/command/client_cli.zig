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
const Direction = mmc.Direction;
const Station = mmc.Station;

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
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file.
        ,
        .execute = &clientConnect,
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
        .short_description = "Set the speed of carrier movement for a line.",
        .long_description =
        \\Set the speed of carrier movement for a line. The line is referenced
        \\by its name. The speed must be a whole integer number between 1 and
        \\100, inclusive.
        ,
        .execute = &clientSetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("SET_SPEED");
    try command.registry.put("SET_ACCELERATION", .{
        .name = "SET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "acceleration percentage" },
        },
        .short_description = "Set the acceleration of carrier movement.",
        .long_description =
        \\Set the acceleration of carrier movement for a line. The line is
        \\referenced by its name. The acceleration must be a whole integer
        \\number between 1 and 100, inclusive.
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
        \\by its name. The speed is a whole integer number between 1 and 100,
        \\inclusive.
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
        .short_description = "Poll and print the X register of a station.",
        .long_description =
        \\Poll and print the X register of a station. The station X register to
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
        .short_description = "Poll and print the Y register of a station.",
        .long_description =
        \\Poll and print the Y register of a station. The station Y register to
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
        .short_description = "Poll and print the Wr register of a station.",
        .long_description =
        \\Poll and print the Wr register of a station. The station Wr register
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
        .short_description = "Poll and print the Ww register of a station.",
        .long_description =
        \\Poll and print the Ww register of a station. The station Ww register
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
    // try command.registry.put("CLEAR_CARRIER_INFO", .{
    //     .name = "CLEAR_CARRIER_INFO",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Clear carrier information at specified axis.",
    //     .long_description =
    //     \\Clear carrier information at specified axis.
    //     ,
    //     .execute = &mclClearCarrierInfo,
    // });
    // errdefer _ = command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    // try command.registry.put("RELEASE_AXIS_SERVO", .{
    //     .name = "RELEASE_AXIS_SERVO",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Release the servo of a given axis.",
    //     .long_description =
    //     \\Release the servo of a given axis, allowing for free carrier movement.
    //     \\This command should be run before carriers move within or exit from
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
    //     \\Calibrate a system line. An uninitialized carrier must be positioned
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
    //     \\Set a system line's zero position based on a current carrier's
    //     \\position. Aforementioned carrier must be located at first axis of
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
    // try command.registry.put("WAIT_RECOVER_CARRIER", .{
    //     .name = "WAIT_RECOVER_CARRIER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "result variable", .resolve = false, .optional = true },
    //     },
    //     .short_description = "Wait until recovery of carrier is complete.",
    //     .long_description =
    //     \\Wait until carrier recovery is complete and a carrier is recognized.
    //     \\If an optional result variable name is provided, then store the
    //     \\recognized carrier ID in the variable.
    //     ,
    //     .execute = &mclWaitRecoverCarrier,
    // });
    // errdefer _ = command.registry.orderedRemove("WAIT_RECOVER_CARRIER");
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
    // try command.registry.put("WAIT_MOVE_CARRIER", .{
    //     .name = "WAIT_MOVE_CARRIER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "carrier" },
    //     },
    //     .short_description = "Wait for carrier movement to complete.",
    //     .long_description =
    //     \\Pause the execution of any further commands until movement for the
    //     \\given carrier is indicated as complete.
    //     ,
    //     .execute = &mclWaitMoveCarrier,
    // });
    // errdefer _ = command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    // try command.registry.put("PUSH_CARRIER_FORWARD", .{
    //     .name = "PUSH_CARRIER_FORWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "carrier" },
    //     },
    //     .short_description = "Push carrier forward by carrier length.",
    //     .long_description =
    //     \\Push carrier forward with speed feedback-controlled movement. This
    //     \\movement targets a distance of the carrier length, and thus if it is
    //     \\used to cross a line boundary, the receiving axis at the destination
    //     \\line must first be pulling the carrier.
    //     ,
    //     .execute = &mclCarrierPushForward,
    // });
    // errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_FORWARD");
    // try command.registry.put("PUSH_CARRIER_BACKWARD", .{
    //     .name = "PUSH_CARRIER_BACKWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "carrier" },
    //     },
    //     .short_description = "Push carrier backward by carrier length.",
    //     .long_description =
    //     \\Push carrier backward with speed feedback-controlled movement. This
    //     \\movement targets a distance of the carrier length, and thus if it is
    //     \\used to cross a line boundary, the receiving axis at the destination
    //     \\line must first be pulling the carrier.
    //     ,
    //     .execute = &mclCarrierPushBackward,
    // });
    // errdefer _ = command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    // try command.registry.put("PULL_CARRIER_FORWARD", .{
    //     .name = "PULL_CARRIER_FORWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "carrier" },
    //     },
    //     .short_description = "Pull incoming carrier forward at axis.",
    //     .long_description =
    //     \\Pull incoming carrier forward at axis. This command must be stopped
    //     \\manually after it is completed with the "STOP_PULL_CARRIER" command.
    //     \\The pulled carrier's ID must also be provided.
    //     ,
    //     .execute = &mclCarrierPullForward,
    // });
    // errdefer _ = command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    // try command.registry.put("PULL_CARRIER_BACKWARD", .{
    //     .name = "PULL_CARRIER_BACKWARD",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //         .{ .name = "carrier" },
    //     },
    //     .short_description = "Pull incoming carrier backward at axis.",
    //     .long_description =
    //     \\Pull incoming carrier backward at axis. This command must be stopped
    //     \\manually after it is completed with the "STOP_PULL_CARRIER" command.
    //     \\The pulled carrier's ID must also be provided.
    //     ,
    //     .execute = &mclCarrierPullBackward,
    // });
    // errdefer _ = command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
    // try command.registry.put("WAIT_PULL_CARRIER", .{
    //     .name = "WAIT_PULL_CARRIER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Wait for carrier pull to complete.",
    //     .long_description =
    //     \\Pause the execution of any further commands until active carrier pull
    //     \\at the provided axis is indicated as complete.
    //     ,
    //     .execute = &mclCarrierWaitPull,
    // });
    // try command.registry.put("STOP_PULL_CARRIER", .{
    //     .name = "STOP_PULL_CARRIER",
    //     .parameters = &[_]command.Command.Parameter{
    //         .{ .name = "line name" },
    //         .{ .name = "axis" },
    //     },
    //     .short_description = "Stop active carrier pull at axis.",
    //     .long_description =
    //     \\Stop active carrier pull at axis.
    //     ,
    //     .execute = &mclCarrierStopPull,
    // });
    // errdefer _ = command.registry.orderedRemove("STOP_PULL_CARRIER");
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
                    std.log.err(
                        "Remaining unexpected line description: {s}",
                        .{line_description.rest()},
                    );
                    return error.UnexpectedDataReceived;
                }
            }
        }
        try mcl.Config.validate(.{ .lines = lines });
        try mcl.init(allocator, .{ .lines = lines });
        for (0..line_numbers) |i| {
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

fn clientSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (carrier_speed < 1 or carrier_speed > 100) return error.InvalidSpeed;

    const line_idx: usize = try matchLine(line_names, line_name);

    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .set_config;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .speed = carrier_speed,
        .acceleration = 0,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (carrier_acceleration < 1 or carrier_acceleration > 100)
        return error.InvalidAcceleration;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .set_config;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .acceleration = carrier_acceleration,
        .speed = 0,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientGetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_speed;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
    };
    if (server) |s| {
        var buffer: [1]u8 = undefined;
        try sendMessage(kind, param, s);
        _ = try s.receive(&buffer);
        const speed = buffer[0];
        std.log.info(
            "Line {s} speed: {d}%",
            .{ line_name, speed },
        );
    } else return error.ServerNotConnected;
}

fn clientGetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .get_acceleration;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
    };
    if (server) |s| {
        var buffer: [1]u8 = undefined;
        try sendMessage(kind, param, s);
        _ = try s.receive(&buffer);
        const acceleration = buffer[0];
        std.log.info(
            "Line {s} acceleration: {d}%",
            .{ line_name, acceleration },
        );
    } else return error.ServerNotConnected;
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
        var buffer: [@sizeOf(mcl.registers.X)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("msg_size: {}", .{msg_size});
        std.log.debug("data: {any}", .{buffer[0..msg_size]});
        std.log.debug("x size: {}", .{@sizeOf(mcl.registers.X)});
        const x = std.mem.bytesToValue(
            mcl.registers.X,
            buffer[0..msg_size],
        );
        std.log.info("{}", .{x});
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
        var buffer: [@sizeOf(mcl.registers.Y)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        const y = std.mem.bytesToValue(
            mcl.registers.Y,
            buffer[0..msg_size],
        );
        std.log.info("{}", .{y});
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
        var buffer: [@sizeOf(mcl.registers.Wr)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        const wr = std.mem.bytesToValue(
            mcl.registers.Wr,
            buffer[0..msg_size],
        );
        std.log.info("{}", .{wr});
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
        var buffer: [@sizeOf(mcl.registers.Ww)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        const ww = std.mem.bytesToValue(
            mcl.registers.Ww,
            buffer[0..msg_size],
        );
        std.log.info("{}", .{ww});
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

    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .axis_carrier;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = @intCast(axis_idx),
    };
    if (server) |s| {
        var buffer: [@sizeOf(u16)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        const carrier_id = std.mem.bytesToValue(
            u16,
            buffer[0..msg_size],
        );
        if (carrier_id != 0) {
            std.log.info(
                "Carrier {d} on axis {d}.\n",
                .{ carrier_id, axis_id },
            );
        } else {
            std.log.info(
                "No carrier recognized on axis {d}.\n",
                .{axis_id},
            );
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .carrier_location;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
    };
    if (server) |s| {
        var buffer: [@sizeOf(i32)]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        const location_int = std.mem.bytesToValue(
            i32,
            buffer[0..msg_size],
        );
        const location: f32 = @bitCast(location_int);
        if (location == -std.math.inf(f32)) {
            std.log.err("Carrier not found", .{});
        } else {
            std.log.info(
                "Carrier {d} location: {d} mm",
                .{ carrier_id, location },
            );
        }
    } else return error.ServerNotConnected;
}

fn clientCarrierAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .carrier_axis;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
    };
    if (server) |s| {
        var buffer: [1024]u8 = undefined;
        try sendMessage(kind, param, s);
        const msg_size = try s.receive(&buffer);
        std.log.debug("data: {s}", .{buffer[0..msg_size]});
        var tokenizer = std.mem.tokenizeSequence(
            u8,
            buffer[0 .. msg_size - 1],
            ",",
        );
        const total_axis = try std.fmt.parseInt(
            usize,
            tokenizer.next().?,
            0,
        );
        for (0..total_axis) |_| {
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier_id, try std.fmt.parseInt(
                    mcl.Axis.Id.Line,
                    tokenizer.next().?,
                    0,
                ) },
            );
        }
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

    const carrier_id: u16 = if (params[3].len > 0)
        try std.fmt.parseInt(u16, params[3], 0)
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

    const axis_index: mmc.Axis.Index.LocalLine = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .isolate;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .axis_idx = axis_index,
        .direction = dir,
        .carrier_id = carrier_id,
        .link_axis = link_axis,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    const axis_index: mmc.Axis.Index.LocalLine = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .move_carrier_axis;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
        .axis_idx = axis_index,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .move_carrier_location;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
        .location = location,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierPosMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx: usize = try matchLine(line_names, line_name);

    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .move_carrier_distance;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
        .distance = distance,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierSpdMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    const line_idx: usize = try matchLine(line_names, line_name);
    const line: mcl.Line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const axis_index: mmc.Axis.Index.LocalLine = @intCast(axis_id - 1);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .spd_move_carrier_axis;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
        .axis_idx = axis_index,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .spd_move_carrier_location;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
        .location = location,
    };
    if (server) |s| try sendMessage(
        kind,
        param,
        s,
    ) else return error.ServerNotConnected;
}

fn clientCarrierSpdMoveDistance(params: [][]const u8) !void {
    const line_name = params[0];
    const carrier_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance = try std.fmt.parseFloat(f32, params[2]);
    const line_idx: usize = try matchLine(line_names, line_name);
    if (distance == 0) {
        std.log.err("Zero distance detected", .{});
        return;
    }
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .spd_move_carrier_distance;
    const param: mmc.ParamType(kind) = .{
        .line_idx = @intCast(line_idx),
        .carrier_id = carrier_id,
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
        mmc.Param,
    ).@"union".tag_type.?,
    param: mmc.ParamType(kind),
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
