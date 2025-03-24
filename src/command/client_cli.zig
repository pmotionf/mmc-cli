const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const mmc = @import("mmc_config");
const network = @import("network");
const CircularBuffer =
    @import("../circular_buffer.zig").CircularBuffer;
const builtin = @import("builtin");

const MMCErrorEnum = @import("mmc_config").MMCErrorEnum;

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
    IP_address = try allocator.alloc(u8, c.IP_address.len);
    @memcpy(IP_address, c.IP_address);
    port = c.port;
    std.log.debug("{s}, {}", .{
        IP_address,
        port,
    });
    try command.registry.put("SERVER_VERSION", .{
        .name = "SERVER_VERSION",
        .short_description = "Display the version of the MMC server",
        .long_description =
        \\Print the currently running version of the MMC server in Semantic 
        \\Version format.
        ,
        .execute = &serverVersion,
    });
    errdefer _ = command.registry.orderedRemove("SERVER_VERSION");
    try command.registry.put("CONNECT", .{
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
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Clear driver errors.",
        .long_description =
        \\Clear driver errors of specified axis. If no axis is provided, clear
        \\driver errors of all axis.
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
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Clear carrier information.",
        .long_description =
        \\Clear carrier information at specified axis. If no axis is provided, 
        \\clear carrier information at all axis
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
    // try command.registry.put("AUTO_INITIALIZE", .{
    //     .name = "AUTO_INITIALIZE",
    //     .short_description = "Initialize all carriers automatically.",
    //     .long_description =
    //     \\Isolate all carriers detected in the system automatically and move the
    //     \\carrier to a free space. Ignore the already initialized carrier. Upon
    //     \\completion, all carrier IDs will be printed and its current location.
    //     ,
    //     .execute = &clientAutoInitialize,
    // });
    // errdefer _ = command.registry.orderedRemove("AUTO_INITIALIZE");
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
    try command.registry.put("WAIT_MOVE_CARRIER", .{
        .name = "WAIT_MOVE_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Wait for carrier movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given carrier is indicated as complete.
        ,
        .execute = &clientWaitMoveCarrier,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_MOVE_CARRIER");
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
    try command.registry.put("WAIT_PULL_CARRIER", .{
        .name = "WAIT_PULL_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Wait for carrier pull to complete.",
        .long_description =
        \\Pause the execution of any further commands until active carrier
        \\pull of the provided carrier is indicated as complete.
        ,
        .execute = &clientCarrrierWaitPull,
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
        .execute = &clientCarrierStopPull,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_CARRIER");
}

pub fn deinit() void {
    arena.deinit();
    line_names = undefined;
    if (main_socket) |s| {
        s.close();
        main_socket = null;
    }
    network.deinit();
}

fn serverVersion(_: [][]const u8) !void {
    var buffer: [8192]u8 = undefined;
    if (main_socket) |s| {
        sendMessage(.get_version, {}, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        waitSocketReceive(s, .Version) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            s.close();
            try disconnectedClearence();
            return;
        };
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        // The first 4 bits are the message type, the following 13 bits are the
        // message length. Actual message start after these bits
        const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
        const IntType = @typeInfo(mmc.Version).@"struct".backing_integer.?;
        const version: mmc.Version = @bitCast(std.mem.readPackedInt(
            IntType,
            &buffer,
            msg_offset,
            .little,
        ));
        std.log.info("MMC Server Version: {d}.{d}.{d}\n", .{
            version.major,
            version.minor,
            version.patch,
        });
    } else {
        return error.NotConnected;
    }
}

pub fn clientConnect(params: [][]const u8) !void {
    std.log.debug("{}", .{params.len});
    if (main_socket != null) return error.ConnectionIsAlreadyEstablished;
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
        var buffer: [1024]u8 = undefined;
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
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

fn disconnectedClearence() !void {
    for (line_names) |name| {
        allocator.free(name);
    }
    allocator.free(line_names);
    allocator.free(line_accelerations);
    allocator.free(line_speeds);
    std.log.info(
        "Disconnected from server {}",
        .{try main_socket.?.getRemoteEndPoint()},
    );
    main_socket = null;
}

pub fn clientDisconnect(_: [][]const u8) !void {
    if (main_socket) |s| {
        s.close();
        try disconnectedClearence();
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
    if (main_socket) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        waitSocketReceive(s, .RegisterX) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            s.close();
            try disconnectedClearence();
            return;
        };
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        // The first 4 bits are the message type, the following 13 bits are the
        // message length. Actual message start after these bits
        const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
        const msg = std.mem.readPackedInt(
            @typeInfo(mcl.registers.X).@"struct".backing_integer.?,
            &buffer,
            msg_offset,
            .little,
        );
        const x: mcl.registers.X = @bitCast(msg);
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
    if (main_socket) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        waitSocketReceive(s, .RegisterY) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            s.close();
            try disconnectedClearence();
            return;
        };
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        // The first 4 bits are the message type, the following 13 bits are the
        // message length. Actual message start after these bits
        const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
        const msg = std.mem.readPackedInt(
            @typeInfo(mcl.registers.Y).@"struct".backing_integer.?,
            &buffer,
            msg_offset,
            .little,
        );
        const y: mcl.registers.Y = @bitCast(msg);
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
    if (main_socket) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        waitSocketReceive(s, .RegisterWr) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            s.close();
            try disconnectedClearence();
            return;
        };
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        // The first 4 bits are the message type, the following 13 bits are the
        // message length. Actual message start after these bits
        const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
        const msg = std.mem.readPackedInt(
            @typeInfo(mcl.registers.Wr).@"struct".backing_integer.?,
            &buffer,
            msg_offset,
            .little,
        );
        const wr: mcl.registers.Wr = @bitCast(msg);
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
    if (main_socket) |s| {
        // The buffer might contain error message from the server
        var buffer: [128]u8 = undefined;
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        waitSocketReceive(s, .RegisterWw) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            s.close();
            try disconnectedClearence();
            return;
        };
        _ = s.receive(&buffer) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        // The first 4 bits are the message type, the following 13 bits are the
        // message length. Actual message start after these bits
        const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
        const msg = std.mem.readPackedInt(
            @typeInfo(mcl.registers.Ww).@"struct".backing_integer.?,
            &buffer,
            msg_offset,
            .little,
        );
        const ww: mcl.registers.Ww = @bitCast(msg);
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

    if (main_socket) |s| {
        // Get carrier status from the server
        const carrier_param: mmc.ParamType(.get_status) = .{
            .kind = .Carrier,
            .line_idx = @truncate(line_idx),
            .axis_idx = axis_idx,
            .carrier_id = 0,
        };
        const carrier = parseCarrierStatus(
            carrier_param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        if (carrier.initialized == false) {
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
    if (main_socket) |s| {
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
    } else return error.ServerNotConnected;
}

fn clientClearErrors(params: [][]const u8) !void {
    if (params[0].len != 0 and params[1].len == 0) return error.MissingParameter;
    var line_idx: mcl.Line.Index = 0;
    var axis_idx: mcl.Axis.Index.Line = 0;
    if (params[1].len > 0) {
        const line_name: []const u8 = params[0];
        line_idx = @intCast(try matchLine(line_names, line_name));
        const line = mcl.lines[line_idx];
        const axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        axis_idx = axis_id - 1;
    }
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .clear_errors;
    const param: mmc.ParamType(kind) = .{
        .line_id = line_idx + 1,
        .axis_idx = axis_idx,
    };
    if (main_socket) |s| {
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
    } else return error.ServerNotConnected;
}

fn clientClearCarrierInfo(params: [][]const u8) !void {
    if (params[0].len != 0 and params[1].len == 0) return error.MissingParameter;
    var line_idx: mcl.Line.Index = 0;
    var axis_idx: mcl.Axis.Index.Line = 0;
    if (params[1].len > 0) {
        const line_name: []const u8 = params[0];
        line_idx = @intCast(try matchLine(line_names, line_name));
        const line = mcl.lines[line_idx];
        const axis_id = try std.fmt.parseInt(
            mcl.Axis.Id.Line,
            params[1],
            0,
        );
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        axis_idx = axis_id - 1;
    }
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .clear_carrier_info;
    const param: mmc.ParamType(kind) = .{
        .line_id = line_idx + 1,
        .axis_idx = axis_idx,
    };
    if (main_socket) |s| {
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
    } else return error.ServerNotConnected;
}

fn clientCarrierLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        // Get carrier status from the server
        const carrier_param: mmc.ParamType(.get_status) = .{
            .kind = .Carrier,
            .line_idx = @truncate(line_idx),
            .axis_idx = 0,
            .carrier_id = carrier_id,
        };
        const carrier = parseCarrierStatus(
            carrier_param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        if (carrier.initialized == false) {
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
        const carrier_param: mmc.ParamType(.get_status) = .{
            .kind = .Carrier,
            .line_idx = @truncate(line_idx),
            .axis_idx = 0,
            .carrier_id = carrier_id,
        };
        const carrier = parseCarrierStatus(
            carrier_param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        if (carrier.initialized == false) {
            std.log.err(
                "Carrier not found",
                .{},
            );
        } else {
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, carrier.axis_idx.main_axis + 1 },
            );
            if (carrier.axis_idx.aux_axis == 0) return;
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, carrier.axis_idx.aux_axis + 1 },
            );
        }
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
    const axis_idx: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    if (main_socket) |s| {
        if (axis_id > 0) {
            // Get hall sensor status from the server
            const hall_param: mmc.ParamType(.get_status) = .{
                .kind = .Hall,
                .line_idx = @truncate(line_idx),
                .axis_idx = axis_idx,
                .carrier_id = 0,
            };
            const hall_sensor = parseHallStatus(
                hall_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            std.log.info(
                "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                .{
                    axis_id,
                    if (hall_sensor.front) "ON" else "OFF",
                    if (hall_sensor.back) "ON" else "OFF",
                },
            );
            return;
        }

        for (line.axes) |axis| {
            // Get carrier status from the server
            const hall_param: mmc.ParamType(.get_status) = .{
                .kind = .Hall,
                .line_idx = @truncate(line_idx),
                .axis_idx = axis.index.line,
                .carrier_id = 0,
            };
            const hall_sensor = parseHallStatus(
                hall_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            std.log.info(
                "Axis {} Hall Sensor:\n\t FRONT - {s}\n\t BACK - {s}",
                .{
                    axis.id.line,
                    if (hall_sensor.front) "ON" else "OFF",
                    if (hall_sensor.back) "ON" else "OFF",
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
        const hall_param: mmc.ParamType(.get_status) = .{
            .kind = .Hall,
            .line_idx = @truncate(line_idx),
            .axis_idx = axis_idx,
            .carrier_id = 0,
        };
        const hall_sensor = parseHallStatus(
            hall_param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        switch (side) {
            .backward => {
                if (hall_sensor.back != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
            .forward => {
                if (hall_sensor.front != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
        }
    } else return error.ServerNotConnected;
}

fn clientMclReset(_: [][]const u8) !void {
    const kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.? = .reset_mcl;
    const param = {};
    if (main_socket) |s| {
        sendMessage(kind, param, s) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
    } else return error.ServerNotConnected;
}

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .Calibration;
    param.line_idx = @truncate(line_idx);
    param.carrier_id = 1;
    if (main_socket) |s| {
        sendMessage(
            .set_command,
            param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
    } else return error.ServerNotConnected;
}

fn clientSetLineZero(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx: usize = try matchLine(line_names, line_name);
    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SetLineZero;
    param.line_idx = @truncate(line_idx);

    if (main_socket) |s| {
        sendMessage(
            .set_command,
            param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
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
    if (main_socket) |s| sendMessage(
        .set_command,
        param,
        s,
    ) catch |e| {
        std.log.debug("{s}", .{@errorName(e)});
        std.log.err("ConnectionClosedByServer", .{});
        s.close();
        try disconnectedClearence();
        return;
    } else return error.ServerNotConnected;
}

fn clientWaitMoveCarrier(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        while (true) {
            try command.checkCommandInterrupt();
            const carrier_param: mmc.ParamType(.get_status) = .{
                .kind = .Carrier,
                .line_idx = @truncate(line_idx),
                .axis_idx = 0,
                .carrier_id = carrier_id,
            };
            const carrier = parseCarrierStatus(
                carrier_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            if (carrier.initialized == false) {
                return error.CarrierNotFound;
            }
            if (carrier.state == .PosMoveCompleted or
                carrier.state == .SpdMoveCompleted) return;
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
    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PositionMoveCarrierAxis;
    param.line_idx = @truncate(line_idx);
    param.axis_idx = axis_index;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
    );
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
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
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

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .PositionMoveCarrierDistance;
    param.line_idx = @truncate(line_idx);
    param.location_distance = distance;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
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

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SpeedMoveCarrierAxis;
    param.line_idx = @truncate(line_idx);
    param.axis_idx = axis_index;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
    );
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
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
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

    var param = std.mem.zeroes(mmc.ParamType(.set_command));
    param.command_code = .SpeedMoveCarrierDistance;
    param.line_idx = @truncate(line_idx);
    param.location_distance = distance;
    param.carrier_id = carrier_id;
    param.speed = line_speeds[line_idx];
    param.acceleration = line_accelerations[line_idx];
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
    );
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
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
    );
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
    try resetReceivedAndSendCommand(
        param,
        @truncate(line_idx),
        carrier_id,
    );
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
    if (main_socket) |s| sendMessage(
        .set_command,
        param,
        s,
    ) catch |e| {
        std.log.debug("{s}", .{@errorName(e)});
        std.log.err("ConnectionClosedByServer", .{});
        s.close();
        try disconnectedClearence();
        return;
    } else return error.ServerNotConnected;
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
    if (main_socket) |s| sendMessage(
        .set_command,
        param,
        s,
    ) catch |e| {
        std.log.debug("{s}", .{@errorName(e)});
        std.log.err("ConnectionClosedByServer", .{});
        s.close();
        try disconnectedClearence();
        return;
    } else return error.ServerNotConnected;
}

fn clientCarrrierWaitPull(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;

    const line_idx: usize = try matchLine(line_names, line_name);

    if (main_socket) |s| {
        while (true) {
            try command.checkCommandInterrupt();
            const carrier_param: mmc.ParamType(.get_status) = .{
                .kind = .Carrier,
                .line_idx = @truncate(line_idx),
                .axis_idx = 0,
                .carrier_id = carrier_id,
            };
            const carrier = parseCarrierStatus(
                carrier_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            if (carrier.state == .PullForwardCompleted or
                carrier.state == .PullBackwardCompleted) return;
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

    var param = std.mem.zeroes(mmc.ParamType(.stop_pull_carrier));
    param.line_idx = @intCast(line_idx);
    param.axis_idx = axis_index;
    if (main_socket) |s| sendMessage(
        .stop_pull_carrier,
        param,
        s,
    ) catch |e| {
        std.log.debug("{s}", .{@errorName(e)});
        std.log.err("ConnectionClosedByServer", .{});
        s.close();
        try disconnectedClearence();
        return;
    } else return error.ServerNotConnected;
}

fn matchLine(names: [][]u8, name: []const u8) !usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    } else {
        return error.LineNameNotFound;
    }
}

/// Wait until a socket receive any messages from the server
fn waitSocketReceive(s: network.Socket, msg_type: mmc.MessageType) !void {
    var peek_buffer: [8192]u8 = undefined;
    while (main_socket) |_| {
        const peek_size = s.peek(&peek_buffer) catch |e| {
            std.log.debug("error message: {s}", .{@errorName(e)});
            return error.ConnectionClosedByServer;
        };
        if (peek_size == 0) return error.ConnectionClosedByServer;
        if (peek_size >= 3) {
            const actual_msg_type = std.mem.readPackedInt(
                u4,
                peek_buffer[0..peek_size],
                0,
                .little,
            );
            if (actual_msg_type != @intFromEnum(msg_type)) {
                const msg = @as(
                    mmc.MessageType,
                    @enumFromInt(actual_msg_type),
                );
                std.log.debug(
                    "Actual message type: {s}, expected: {s}",
                    .{ @tagName(msg), @tagName(msg_type) },
                );
                _ = s.receive(&peek_buffer) catch |e| {
                    std.log.debug("error message: {s}", .{@errorName(e)});
                    return error.ConnectionClosedByServer;
                };
                return error.UnexpectedMessage;
            }
            const msg_length = std.mem.readPackedInt(
                u13,
                peek_buffer[0..peek_size],
                4,
                .little,
            );
            if (peek_size >= msg_length) {
                return;
            }
        }
    }
}

fn sendMessage(
    comptime kind: @typeInfo(
        mmc.Param,
    ).@"union".tag_type.?,
    param: mmc.ParamType(kind),
    to_server: network.Socket,
) !void {
    const command_msg: mmc.CommandMessage(kind) =
        .{
            .kind = @intFromEnum(kind),
            ._unused_kind = 0,
            .param = param,
            ._rest_param = 0,
        };
    // The first 4 bits are the message type, the following 13 bits are the
    // message length. Actual message start after these bits.
    const msg_length_bit = @bitSizeOf(u4) + @bitSizeOf(u13) + @bitSizeOf(@TypeOf(command_msg));
    const msg_size = if (msg_length_bit % 8 != 0)
        msg_length_bit / 8 + 1
    else
        msg_length_bit;
    var msg_buffer: [msg_size]u8 = undefined;
    comptime var msg_bit_size = 0;
    std.mem.writePackedInt(
        u4,
        &msg_buffer,
        msg_bit_size,
        @intFromEnum(mmc.MessageType.Command),
        .little,
    );
    msg_bit_size += @bitSizeOf(u4);
    std.mem.writePackedInt(
        u13,
        &msg_buffer,
        msg_bit_size,
        msg_size,
        .little,
    );
    msg_bit_size += @bitSizeOf(u13);
    std.mem.writePackedInt(
        std.meta.Int(
            .unsigned,
            @bitSizeOf(@TypeOf(command_msg)),
        ),
        &msg_buffer,
        msg_bit_size,
        @bitCast(command_msg),
        .little,
    );
    msg_bit_size += @bitSizeOf(@TypeOf(command_msg));
    try to_server.writer().writeAll(&msg_buffer);
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

// fn getFreeAxisIndex(
//     start_hall_idx: usize,
//     end_hall_idx: usize,
//     direction: Direction,
// ) !usize {
//     const start_axis_idx = if (start_hall_idx % 2 == 0)
//         start_hall_idx / 2
//     else
//         start_hall_idx / 2 + 1;
//     const end_axis_idx = if (end_hall_idx % 2 == 0)
//         end_hall_idx / 2 - 1
//     else
//         end_hall_idx / 2;
//     var result = if (direction == .backward) start_axis_idx else end_axis_idx;
//     std.log.debug(
//         "result: {}, direction: {s}, start: {}, end: {}",
//         .{ result, @tagName(direction), start_axis_idx, end_axis_idx },
//     );

//     status_lock.lock();
//     const num_of_active_axis = system_state.num_of_active_axis;
//     status_lock.unlock();
//     for (0..num_of_active_axis) |i| {
//         status_lock.lock();
//         const hall_sensor = system_state.hall_sensors[i];
//         status_lock.unlock();
//         if (hall_sensor.axis_id - 1 == result) {
//             if (direction == .forward and hall_sensor.hall_states.front) {
//                 std.log.debug(
//                     "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
//                     .{ direction == .forward, hall_sensor.hall_states.front },
//                 );
//                 result -= 1;
//             } else if (direction == .backward and hall_sensor.hall_states.back) {
//                 std.log.debug(
//                     "direction == .forward -> {}, hall_sensor.hall_states.front -> {}",
//                     .{ direction == .forward, hall_sensor.hall_states.front },
//                 );
//                 result += 1;
//             }
//         }
//         std.log.debug("result: {}", .{result});
//     }
//     return result;
// }

// fn checkHallStatus(hall_index: usize) !bool {
//     const hall_axis_id = hall_index / 2 + 1;
//     status_lock.lock();
//     const num_of_active_axis = system_state.num_of_active_axis;
//     status_lock.unlock();
//     for (0..num_of_active_axis) |i| {
//         status_lock.lock();
//         const hall_sensor = system_state.hall_sensors[i];
//         status_lock.unlock();
//         if (hall_axis_id == hall_sensor.axis_id) {
//             if ((hall_index % 2 == 0 and hall_sensor.hall_states.back) or
//                 (hall_index % 2 != 0 and hall_sensor.hall_states.front))
//             {
//                 return true;
//             }
//         }
//     }
//     return false;
// }

// /// check if there is a carrier at the specified axis
// fn checkCarrierExistence(
//     main_idx: usize,
//     aux_idx: usize,
// ) !?struct { usize, usize } {
//     status_lock.lock();
//     const num_of_carriers = system_state.num_of_carriers;
//     status_lock.unlock();
//     for (0..num_of_carriers) |i| {
//         status_lock.lock();
//         const carrier = system_state.carriers[i];
//         status_lock.unlock();
//         if ((carrier.axis_ids.first == main_idx + 1 or
//             carrier.axis_ids.second == main_idx + 1) and
//             (carrier.state == .BackwardIsolationCompleted or
//                 carrier.state == .ForwardIsolationCompleted))
//         {
//             return .{ carrier.id, main_idx };
//         }
//         if ((carrier.axis_ids.first == aux_idx + 1 or
//             carrier.axis_ids.second == aux_idx + 1) and
//             (carrier.state == .BackwardIsolationCompleted or
//                 carrier.state == .ForwardIsolationCompleted))
//         {
//             return .{ carrier.id, aux_idx };
//         }
//     }
//     return null;
// }

// /// Map the hall sensor status from the server to `hall_sensors` variable
// fn mapHallSensors(
//     hall_sensors: []bool,
//     starting_axis_indices: []usize,
// ) ![]bool {
//     status_lock.lock();
//     const num_of_active_axis = system_state.num_of_active_axis;
//     status_lock.unlock();
//     for (0..num_of_active_axis) |i| {
//         status_lock.lock();
//         const hall_sensor = system_state.hall_sensors[i];
//         status_lock.unlock();
//         std.log.debug("line id from hall sensor: {}", .{hall_sensor.line_id});
//         const back_idx = starting_axis_indices[hall_sensor.line_id - 1] +
//             (hall_sensor.axis_id - 1) * 2;
//         const front_idx = starting_axis_indices[hall_sensor.line_id - 1] +
//             (hall_sensor.axis_id - 1) * 2 + 1;
//         hall_sensors[back_idx] = hall_sensor.hall_states.back;
//         hall_sensors[front_idx] = hall_sensor.hall_states.front;
//     }
//     return hall_sensors;
// }

// /// assert that current axis does not have a moving carrier
// fn assertNoProgressing(axis_idx: usize) !bool {
//     status_lock.lock();
//     const num_of_carriers = system_state.num_of_carriers;
//     status_lock.unlock();
//     for (0..num_of_carriers) |i| {
//         status_lock.lock();
//         const carrier = system_state.carriers[i];
//         status_lock.unlock();
//         if ((carrier.axis_ids.first == axis_idx + 1 or
//             carrier.axis_ids.second == axis_idx + 1) and
//             (carrier.state == .ForwardIsolationProgressing or
//                 carrier.state == .BackwardIsolationProgressing))
//         {
//             return false;
//         }
//     }
//     return true;
// }

fn resetReceivedAndSendCommand(
    param: mmc.ParamType(.set_command),
    line_idx: mcl.Line.Index,
    carrier_id: u10,
) !void {
    const reset_param: mmc.ParamType(.clear_command_status) = .{
        .line_idx = line_idx,
        .carrier_id = carrier_id,
        .status = .StateAndReceived,
    };

    const reset_command_response_param: mmc.ParamType(.clear_command_status) = .{
        .line_idx = line_idx,
        .carrier_id = carrier_id,
        .status = .Response,
    };

    if (main_socket) |s| {
        sendMessage(
            .clear_command_status,
            reset_param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };
        std.log.info("Waiting command received", .{});
        while (true) {
            const carrier_param: mmc.ParamType(.get_status) = .{
                .kind = .Carrier,
                .line_idx = @truncate(line_idx),
                .axis_idx = 0,
                .carrier_id = carrier_id,
            };
            const carrier = parseCarrierStatus(
                carrier_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            if (carrier.command_received == false) break;
        }

        sendMessage(
            .set_command,
            param,
            s,
        ) catch |e| {
            std.log.debug("{s}", .{@errorName(e)});
            std.log.err("ConnectionClosedByServer", .{});
            s.close();
            try disconnectedClearence();
            return;
        };

        while (true) {
            try command.checkCommandInterrupt();
            const carrier_param: mmc.ParamType(.get_status) = .{
                .kind = .Carrier,
                .line_idx = @truncate(line_idx),
                .axis_idx = 0,
                .carrier_id = carrier_id,
            };
            const carrier = parseCarrierStatus(
                carrier_param,
                s,
            ) catch |e| {
                std.log.debug("{s}", .{@errorName(e)});
                std.log.err("ConnectionClosedByServer", .{});
                s.close();
                try disconnectedClearence();
                return;
            };
            if (carrier.command_received) {
                if (carrier.command_response != .NoError) {
                    sendMessage(
                        .clear_command_status,
                        reset_command_response_param,
                        s,
                    ) catch |e| {
                        std.log.debug("{s}", .{@errorName(e)});
                        std.log.err("ConnectionClosedByServer", .{});
                        s.close();
                        try disconnectedClearence();
                        return;
                    };
                }
                return switch (carrier.command_response) {
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
        }
    } else return error.ServerNotConnected;
}

fn parseCarrierStatus(
    param: mmc.ParamType(.get_status),
    socket: network.Socket,
) !SystemState.Carrier {
    try sendMessage(.get_status, param, socket);
    // The size of get_status command is based on SystemState.Carrier
    const bit_max_size = 4 + 13 + @bitSizeOf(SystemState.Carrier);
    const max_size = if (bit_max_size % 8 == 0)
        bit_max_size / 8
    else
        (bit_max_size / 8) + 1;
    var buffer = std.mem.zeroes([max_size]u8);
    _ = try socket.receive(&buffer);
    // The first 4 bits are the message type, the following 13 bits are the
    // message length. Actual message start after these bits
    const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
    const IntType =
        @typeInfo(SystemState.Carrier).@"struct".backing_integer.?;
    const carrier_int = std.mem.readPackedInt(
        IntType,
        &buffer,
        msg_offset,
        .little,
    );
    return @bitCast(carrier_int);
}

fn parseHallStatus(
    param: mmc.ParamType(.get_status),
    socket: network.Socket,
) !SystemState.Hall {
    try sendMessage(.get_status, param, socket);
    // The size of get_status command is based on SystemState.Carrier
    const bit_max_size = 4 + 13 + @bitSizeOf(SystemState.Carrier);
    const max_size = if (bit_max_size % 8 == 0)
        bit_max_size / 8
    else
        (bit_max_size / 8) + 1;
    var buffer = std.mem.zeroes([max_size]u8);
    _ = try socket.receive(&buffer);
    // The first 4 bits are the message type, the following 13 bits are the
    // message length. Actual message start after these bits
    const msg_offset: usize = @bitSizeOf(u4) + @bitSizeOf(u13);
    const IntType =
        @typeInfo(SystemState.Hall).@"struct".backing_integer.?;
    const hall_int = std.mem.readPackedInt(
        IntType,
        &buffer,
        msg_offset,
        .little,
    );
    return @bitCast(hall_int);
}
