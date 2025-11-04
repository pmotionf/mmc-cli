const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");

const CircularBufferAlloc =
    @import("../circular_buffer.zig").CircularBufferAlloc;
const command = @import("../command.zig");
pub const Line = @import("mmc_client/Line.zig");
pub const Log = @import("mmc_client/Log.zig");
pub const zignet = @import("zignet");
// pub const api = @import("mmc_client/api.zig");
pub const api = @import("mmc-api");

const commands = struct {
    const auto_initialize =
        @import("mmc_client/commands/auto_initialize.zig");
    const release_carrier =
        @import("mmc_client/commands/release_carrier.zig");
    const clear_errors = @import("mmc_client/commands/clear_errors.zig");
    const clear_carrier_info =
        @import("mmc_client/commands/clear_carrier_info.zig");
    const reset_system = @import("mmc_client/commands/reset_system.zig");
    const calibrate = @import("mmc_client/commands/calibrate.zig");
    const set_line_zero = @import("mmc_client/commands/set_line_zero.zig");
    const isolate = @import("mmc_client/commands/isolate.zig");
    const wait = @import("mmc_client/commands/wait.zig");
    const move = @import("mmc_client/commands/move.zig");
    const push = @import("mmc_client/commands/push.zig");
    const pull = @import("mmc_client/commands/pull.zig");
    const stop_pull = @import("mmc_client/commands/stop_pull.zig");
    const stop_push = @import("mmc_client/commands/stop_push.zig");
    const set_carrier_id = @import("mmc_client/commands/set_carrier_id.zig");
    const stop = @import("mmc_client/commands/stop.zig");
    const pause = @import("mmc_client/commands/pause.zig");
    const @"resume" = @import("mmc_client/commands/resume.zig");
    const connect = @import("mmc_client/commands/connect.zig");
    const disconnect = @import("mmc_client/commands/disconnect.zig");
    const log = @import("mmc_client/commands/log.zig");
    const set_speed = @import("mmc_client/commands/set_speed.zig");
    const get_speed = @import("mmc_client/commands/get_speed.zig");
    const set_acceleration =
        @import("mmc_client/commands/set_acceleration.zig");
    const get_acceleration =
        @import("mmc_client/commands/get_acceleration.zig");
    const assert_hall = @import("mmc_client/commands/assert_hall.zig");
    const hall_status = @import("mmc_client/commands/hall_status.zig");
    const carrier_axis = @import("mmc_client/commands/carrier_axis.zig");
    const carrier_location =
        @import("mmc_client/commands/carrier_location.zig");
    const assert_location = @import("mmc_client/commands/assert_location.zig");
    const carrier_id = @import("mmc_client/commands/carrier_id.zig");
    const axis_carrier = @import("mmc_client/commands/axis_carrier.zig");
    const print_carrier_info =
        @import("mmc_client/commands/print_carrier_info.zig");
    const print_axis_info =
        @import("mmc_client/commands/print_axis_info.zig");
    const print_driver_info =
        @import("mmc_client/commands/print_driver_info.zig");
    const show_errors = @import("mmc_client/commands/show_errors.zig");
    const server_version = @import("mmc_client/commands/server_version.zig");
};

pub const error_response = struct {
    /// Throw an error if receive response of core request error
    pub fn throwCoreError(err: api.protobuf.mmc.core.Request.Error) anyerror {
        return switch (err) {
            .CORE_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
            .CORE_REQUEST_ERROR_REQUEST_UNKNOWN => error.RequestUnknown,
            _ => return error.UnexpectedResponse,
        };
    }

    pub fn throwCommandError(err: api.protobuf.mmc.command.Request.Error) anyerror {
        return switch (err) {
            .COMMAND_REQUEST_ERROR_UNSPECIFIED,
            .COMMAND_REQUEST_ERROR_INVALID_LOCATION,
            .COMMAND_REQUEST_ERROR_INVALID_DISTANCE,
            .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED,
            => error.InvalidResponse,
            .COMMAND_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
            .COMMAND_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
            .COMMAND_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
            .COMMAND_REQUEST_ERROR_INVALID_ACCELERATION => error.InvalidAcceleration,
            .COMMAND_REQUEST_ERROR_INVALID_VELOCITY => error.InvalidSpeed,
            .COMMAND_REQUEST_ERROR_INVALID_DIRECTION => error.InvalidDirection,
            .COMMAND_REQUEST_ERROR_INVALID_CARRIER => error.InvalidCarrier,
            .COMMAND_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
            .COMMAND_REQUEST_ERROR_COMMAND_NOT_FOUND => error.CommandNotFound,
            .COMMAND_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
            .COMMAND_REQUEST_ERROR_OUT_OF_MEMORY => error.ServerRunningOutOfMemory,
            .COMMAND_REQUEST_ERROR_MAXIMUM_AUTO_INITIALIZE_EXCEEDED => error.MaximumAutoInitializeExceeded,
            .COMMAND_REQUEST_ERROR_CONFLICTING_CARRIER_ID => error.ConflictingCarrierId,
            _ => return error.UnexpectedResponse,
        };
    }

    pub fn throwInfoError(err: api.protobuf.mmc.info.Request.Error) anyerror {
        return switch (err) {
            .INFO_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
            .INFO_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
            .INFO_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
            .INFO_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
            .INFO_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
            _ => return error.UnexpectedResponse,
        };
    }

    pub fn throwMmcError(err: api.protobuf.mmc.Request.Error) anyerror {
        return switch (err) {
            .MMC_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
            .MMC_REQUEST_ERROR_INVALID_MESSAGE => error.InvalidMessage,
            _ => return error.UnexpectedResponse,
        };
    }
};

pub const Filter = union(enum) {
    carrier: [1]u32,
    driver: u32,
    axis: u32,

    pub fn parse(filter: []const u8) (error{InvalidParameter} || std.fmt.ParseIntError)!Filter {
        var suffix_idx: usize = 0;
        for (filter) |c| {
            if (std.ascii.isDigit(c)) suffix_idx += 1 else break;
        }
        // No digit is recognized.
        if (suffix_idx == 0) return error.InvalidParameter;
        const id = try std.fmt.parseUnsigned(u32, filter[0..suffix_idx], 0);

        // Check for single character suffix.
        if (filter.len - suffix_idx == 1) {
            if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "a"))
                return Filter{ .axis = id }
            else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "c"))
                return Filter{ .carrier = [1]u32{id} }
            else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "d"))
                return Filter{ .driver = id };
        }
        // Check for `axis` suffix
        else if (filter.len - suffix_idx == 4 and
            std.ascii.eqlIgnoreCase(filter[suffix_idx..], "axis"))
            return Filter{ .axis = id }
            // Check for `driver` suffix
        else if (filter.len - suffix_idx == 6 and
            std.ascii.eqlIgnoreCase(filter[suffix_idx..], "driver"))
            return Filter{ .driver = id }
            // Check for `carrier` suffix
        else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "carrier"))
            return Filter{ .carrier = [1]u32{id} };
        return error.InvalidParameter;
    }

    pub fn toProtobuf(filter: *Filter) api.protobuf.mmc.info.Request.Track.filter_union {
        return switch (filter.*) {
            .axis => |axis_id| .{
                .axes = .{
                    .start = axis_id,
                    .end = axis_id,
                },
            },
            .driver => |driver_id| .{
                .drivers = .{
                    .start = driver_id,
                    .end = driver_id,
                },
            },
            .carrier => .{
                .carriers = .{ .ids = .fromOwnedSlice(&filter.carrier) },
            },
        };
    }
};

/// `lines` is initialized once the client is connected to a server.
/// Deinitialized once disconnected from a server.
pub var lines: []Line = &.{};
/// `log` is initialized once the client is connected to a server. Deinitialized
/// once disconnected from a server.
pub var log: Log = undefined;
/// Currently connected socket. Nulled when disconnect.
pub var sock: ?zignet.Socket = null;
/// Currently saved endpoint. The endpoint will be overwritten if the client
/// is connected to a different server. Stays null before connected to a socket.
pub var endpoint: ?zignet.Endpoint = null;

var arena: std.heap.ArenaAllocator = undefined;
pub var allocator: std.mem.Allocator = undefined;

pub var log_allocator: std.mem.Allocator = undefined;
pub const Config = struct {
    host: []u8,
    port: u16,
};
/// Store the configuration.
pub var config: Config = undefined;

/// Reader buffer for network stream
pub var reader_buf: [4096]u8 = undefined;
/// Writer buffer for network stream
pub var writer_buf: [4096]u8 = undefined;

pub var reader: zignet.Socket.Reader = undefined;
pub var writer: zignet.Socket.Writer = undefined;

var debug_allocator = std.heap.DebugAllocator(.{}){};

pub fn init(c: Config) !void {
    arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    errdefer arena.deinit();
    allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        arena.allocator();
    config = .{
        .host = try allocator.dupe(u8, c.host),
        .port = c.port,
    };
    errdefer allocator.free(config.host);

    try command.registry.put(.{
        .name = "SERVER_VERSION",
        .short_description = "Display the version of the MMC server",
        .long_description =
        \\Print the currently running version of the MMC server in Semantic
        \\Version format.
        ,
        .execute = &commands.server_version.impl,
    });
    errdefer command.registry.orderedRemove("SERVER_VERSION");
    try command.registry.put(.{
        .name = "CONNECT",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "endpoint", .optional = true },
        },
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file. The port
        \\and IP address can be overwritten by providing the new port and IP
        \\address by specifying the endpoint as "IP_ADDRESS:PORT".
        ,
        .execute = &commands.connect.impl,
    });
    errdefer command.registry.orderedRemove("CONNECT");
    try command.registry.put(.{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End connection with the mmc server.
        ,
        .execute = &commands.disconnect.impl,
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
        \\to 6.0 meters-per-second.
        ,
        .execute = &commands.set_speed.impl,
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
        \\less than or equal to 24.5 meters-per-second-squared.
        ,
        .execute = &commands.set_acceleration.impl,
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
        \\by name. Speed is in meters-per-second.
        ,
        .execute = &commands.get_speed.impl,
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
        \\referenced by name. Acceleration is in meters-per-second-squared.
        ,
        .execute = &commands.get_acceleration.impl,
    });
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
        .name = "PRINT_AXIS_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter" },
        },
        .short_description = "Print the axis information.",
        .long_description =
        \\Print the axis information. The information is shown based on the 
        \\given filter, which shall be provided with the ID followed by suffix. 
        \\The supported suffixes are "c" or "carrier" for filtering based on 
        \\carrier, "d" or "driver" for filtering based on "driver", and "a" or 
        \\"axis" for filtering based on "axis".
        ,
        .execute = &commands.print_axis_info.impl,
    });
    errdefer command.registry.orderedRemove("PRINT_AXIS_INFO");
    try command.registry.put(.{
        .name = "PRINT_DRIVER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter" },
        },
        .short_description = "Print the driver information.",
        .long_description =
        \\Print the information information. The information is shown based on 
        \\the given filter, which shall be provided with the ID followed by 
        \\suffix. The supported suffixes are "c" or "carrier" for filtering 
        \\based on carrier, "d" or "driver" for filtering based on "driver", and
        \\"a" or "axis" for filtering based on "axis".
        ,
        .execute = &commands.print_driver_info.impl,
    });
    errdefer command.registry.orderedRemove("PRINT_DRIVER_INFO");
    try command.registry.put(.{
        .name = "PRINT_CARRIER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter" },
        },
        .short_description = "Print the carrier information.",
        .long_description =
        \\Print the carrier information. The information is shown based on the 
        \\given filter, which shall be provided with the ID followed by suffix 
        \\The supported suffixes are "c" or "carrier" for filtering based on 
        \\carrier, "d" or "driver" for filtering based on "driver", and "a" or 
        \\"axis" for filtering based on "axis".
        ,
        .execute = &commands.print_carrier_info.impl,
    });
    errdefer command.registry.orderedRemove("PRINT_CARRIER_INFO");
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
        \\the variable. The result variable is case sensitive and shall not 
        \\begin with digit.
        ,
        .execute = &commands.axis_carrier.impl,
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
        \\parameter with comma separator, e.g., "front,back,tr". If a result 
        \\variable prefix is provided, store all carrier IDs in the variable 
        \\with the variable name: prefix[num], e.g., prefix1 and prefix2 if 
        \\two carriers exist on the provided line(s). The result variable prefix 
        \\is case sensitive and shall not begin with digit.
        ,
        .execute = &commands.carrier_id.impl,
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
        .execute = &commands.assert_location.impl,
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
        \\the carrier's location in the variable. The result variable is case 
        \\sensitive and shall not begin with digit.
        ,
        .execute = &commands.carrier_location.impl,
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
        .execute = &commands.carrier_axis.impl,
    });
    errdefer command.registry.orderedRemove("CARRIER_AXIS");
    try command.registry.put(.{
        .name = "HALL_STATUS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Display hall status state.",
        .long_description =
        \\Display hall status state. The information is shown based on the 
        \\given filter, which shall be provided with the ID followed by suffix 
        \\The supported suffixes are "c" or "carrier" for filtering based on 
        \\carrier, "d" or "driver" for filtering based on "driver", and "a" or 
        \\"axis" for filtering based on "axis". If no filter is provided, show
        \\all hall status across the line.
        ,
        .execute = &commands.hall_status.impl,
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
        .execute = &commands.assert_hall.impl,
    });
    errdefer command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put(.{
        .name = "CLEAR_ERRORS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Clear errors state.",
        .long_description =
        \\Clear errors state on axis and driver. The driver in which error to be 
        \\cleared is selected based on the given filter, which shall be provided 
        \\with the ID followed by suffix. The supported suffixes are "c" or 
        \\"carrier" for filtering based on carrier, "d" or "driver" for 
        \\filtering based on "driver", and "a" or "axis" for filtering based on 
        \\"axis". If no filter is provided, clear errors on all drivers.
        ,
        .execute = &commands.clear_errors.impl,
    });
    errdefer command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(.{
        .name = "CLEAR_CARRIER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Clear carrier information.",
        .long_description =
        \\Clear carrier information. The carrier to be cleared is selected based 
        \\on the given filter, which shall be provided with the ID followed by 
        \\suffix. The supported suffixes are "c" or "carrier" for filtering 
        \\based on carrier, "d" or "driver" for filtering based on "driver", and 
        \\"a" or "axis" for filtering based on "axis". If no filter is provided, 
        \\clear errors on all drivers.
        ,
        .execute = &commands.clear_carrier_info.impl,
    });
    errdefer command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    try command.registry.put(.{
        .name = "RESET_SYSTEM",
        .short_description = "Reset the system state.",
        .long_description =
        \\Clear any carrier and errors occurred across the system. In addition,
        \\reset any push and pull state on every axis.
        ,
        .execute = &commands.reset_system.impl,
    });
    errdefer command.registry.orderedRemove("RESET_SYSTEM");
    try command.registry.put(.{
        .name = "RELEASE_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Release the carrier for being controlled",
        .long_description =
        \\Release the motor that control the carrier, allowing for free 
        \\carrier movement. This command should be run before carriers move 
        \\within or exit from the track due to external influence. The carrier
        \\to be released from control is selected based on the given filter, 
        \\which shall be provided with the ID followed by suffix. The 
        \\supported suffixes are "c" or "carrier" for filtering based on 
        \\carrier, "d" or "driver" for filtering based on "driver", and "a" or 
        \\"axis" for filtering based on "axis". If no filter is provided, clear 
        \\errors on all drivers.
        ,
        .execute = &commands.release_carrier.impl,
    });
    errdefer command.registry.orderedRemove("RELEASE_CARRIER");
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
        .execute = &commands.auto_initialize.impl,
    });
    errdefer command.registry.orderedRemove("AUTO_INITIALIZE");
    try command.registry.put(.{
        .name = "CALIBRATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Calibrate a track line.",
        .long_description =
        \\Calibrate a track line. An uninitialized carrier must be positioned
        \\at the start of the line such that the first axis has both hall
        \\alarms active.
        ,
        .execute = &commands.calibrate.impl,
    });
    errdefer command.registry.orderedRemove("CALIBRATE");
    try command.registry.put(.{
        .name = "SET_LINE_ZERO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Set line zero position.",
        .long_description =
        \\Set a line's zero position based on a current carrier's position. 
        \\Aforementioned carrier must be located at first axis of line.
        ,
        .execute = &commands.set_line_zero.impl,
    });
    errdefer command.registry.orderedRemove("SET_LINE_ZERO");
    try command.registry.put(.{
        .name = "ISOLATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
            .{ .name = "carrier id" },
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
        .execute = &commands.isolate.impl,
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
        .execute = &commands.wait.isolate,
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
        .execute = &commands.wait.moveCarrier,
    });
    errdefer command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put(.{
        .name = "MOVE_CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination axis" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system. Provide "true" to disable
        \\CAS (collision avoidance system) for the command.
        ,
        .execute = &commands.move.posAxis,
    });
    errdefer command.registry.orderedRemove("MOVE_CARRIER_AXIS");
    try command.registry.put(.{
        .name = "MOVE_CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination location" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target location.",
        .long_description =
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. Provide "true" to
        \\disable CAS (collision avoidance system) for the command.
        ,
        .execute = &commands.move.posLocation,
    });
    errdefer command.registry.orderedRemove("MOVE_CARRIER_LOCATION");
    try command.registry.put(.{
        .name = "MOVE_CARRIER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "distance" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier by a distance.",
        .long_description =
        \\Move given carrier by a provided distance. The carrier ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement. Provide "true" to disable
        \\CAS (collision avoidance system) for the command.
        ,
        .execute = &commands.move.posDistance,
    });
    errdefer command.registry.orderedRemove("MOVE_CARRIER_DISTANCE");
    try command.registry.put(.{
        .name = "SPD_MOVE_CARRIER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination axis" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system. This command moves the
        \\carrier with speed profile feedback. Provide "true" to disable CAS
        \\(collision avoidance system) for the command.
        ,
        .execute = &commands.move.spdAxis,
    });
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_AXIS");
    try command.registry.put(.{
        .name = "SPD_MOVE_CARRIER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "destination location" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target location.",
        .long_description =
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. This command
        \\moves the carrier with speed profile feedback. Provide "true" to disable
        \\CAS (collision avoidance system) for the command.
        ,
        .execute = &commands.move.spdLocation,
    });
    errdefer command.registry.orderedRemove("SPD_MOVE_CARRIER_LOCATION");
    try command.registry.put(.{
        .name = "SPD_MOVE_CARRIER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
            .{ .name = "distance" },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier by a distance.",
        .long_description =
        \\Move given carrier by a provided distance. The carrier ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement. This command moves the carrier
        \\with speed profile feedback. Provide "true" to disable CAS (collision
        \\avoidance system) for the command.
        ,
        .execute = &commands.move.spdDistance,
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
        .execute = &commands.push.forward,
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
        .execute = &commands.push.backward,
    });
    errdefer command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    try command.registry.put(.{
        .name = "PULL_CARRIER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
            .{ .name = "destination", .optional = true },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Pull incoming carrier forward at axis.",
        .long_description =
        \\Pull incoming carrier forward at axis. The pulled carrier's new ID
        \\must also be provided. If a destination in millimeters is specified,
        \\the carrier will automatically move to the destination after pull is
        \\completed. Provide "true" to disable CAS (collision avoidance system)
        \\for the command when the final destination is provided.
        ,
        .execute = &commands.pull.forward,
    });
    errdefer command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    try command.registry.put(.{
        .name = "PULL_CARRIER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "carrier" },
            .{ .name = "destination", .optional = true },
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Pull incoming carrier backward at axis.",
        .long_description =
        \\Pull incoming carrier backward at axis. The pulled carrier's new ID
        \\must also be provided. If a destination in millimeters is specified,
        \\the carrier will automatically move to the destination after pull is
        \\completed. Provide "true" to disable CAS (collision avoidance system)
        \\for the command when the final destination is provided.
        ,
        .execute = &commands.pull.backward,
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
        .execute = &commands.wait.pull,
    });
    errdefer command.registry.orderedRemove("WAIT_PULL_CARRIER");
    try command.registry.put(.{
        .name = "STOP_PULL_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Stop active carrier pull at axis.",
        .long_description =
        \\Stop active carrier pull at axis. The axis is selected based on the 
        \\given filter, which shall be provided with the ID followed by suffix. 
        \\The supported suffixes are "d" or "driver" for filtering based on 
        \\"driver" and "a" or "axis" for filtering based on "axis". If no 
        \\filter is provided, clear errors on all drivers.
        ,
        .execute = &commands.stop_pull.impl,
    });
    errdefer command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put(.{
        .name = "STOP_PUSH_CARRIER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Stop active carrier push at axis.",
        .long_description =
        \\Stop active carrier push at axis. The axis is selected based on the 
        \\given filter, which shall be provided with the ID followed by suffix. 
        \\The supported suffixes are "d" or "driver" for filtering based on 
        \\"driver" and "a" or "axis" for filtering based on "axis". If no 
        \\filter is provided, clear errors on all drivers.
        ,
        .execute = &commands.stop_push.impl,
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
        .execute = &commands.wait.axisEmpty,
    });
    errdefer command.registry.orderedRemove("WAIT_AXIS_EMPTY");
    try command.registry.put(.{
        .name = "ADD_LOG_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "kind" },
            .{ .name = "range", .optional = true },
        },
        .short_description = "Add info logging configuration.",
        .long_description =
        \\Add an info logging configuration. This command overwrites the existing
        \\logging configuration for the specified line, if any. The "kind" stands
        \\for the kind of info to be logged, specified by either "driver", "axis",
        \\or "all" to log both driver and axis info. The range is the inclusive
        \\axis range, and shall be provided with colon separated value, e.g. "1:9"
        \\to log from axis 1 to 9. Leaving the range will log every axis on the
        \\line.
        ,
        .execute = &commands.log.add,
    });
    errdefer command.registry.orderedRemove("ADD_LOG_INFO");
    try command.registry.put(.{
        .name = "START_LOG_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "duration" },
            .{ .name = "path", .optional = true },
        },
        .short_description = "Add info logging configuration.",
        .long_description =
        \\Start the info logging process. The log file contains only the most
        \\recent data covering the specified duration (in seconds). The logging
        \\runs until error occurs or is cancelled by executing "STOP_LOGGING".
        \\If no path is provided, a default log file will be created in the
        \\current working directory as: "mmc-logging-YYYY.MM.DD-HH.MM.SS.csv".
        ,
        .execute = &commands.log.start,
    });
    errdefer command.registry.orderedRemove("START_LOG_INFO");
    try command.registry.put(.{
        .name = "REMOVE_LOG_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line", .optional = true },
        },
        .short_description = "Remove the logging configuration.",
        .long_description =
        \\Remove logging configuration for logging info. Providing a line removes
        \\the logging configuration for the specified line. Otherwise, removes
        \\the logging configurations for all lines.
        ,
        .execute = &commands.log.remove,
    });
    errdefer command.registry.orderedRemove("REMOVE_LOG_INFO");
    try command.registry.put(.{
        .name = "STATUS_LOG_INFO",
        .short_description = "Show the logging configuration(s).",
        .long_description =
        \\Show the logging configuration for each line, if any.
        ,
        .execute = &commands.log.status,
    });
    errdefer command.registry.orderedRemove("STATUS_LOG_INFO");
    try command.registry.put(.{
        .name = "STOP_LOG_INFO",
        .short_description = "Stop the mmc logging process.",
        .long_description =
        \\Stop the mmc logging process if the logging is already started, and
        \\save the logging data to the log file.
        ,
        .execute = &commands.log.stop,
    });
    errdefer command.registry.orderedRemove("STOP_LOG_INFO");
    try command.registry.put(.{
        .name = "PRINT_ERRORS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Print axis and driver errors.",
        .long_description =
        \\Print axis and driver errors on a line, if any. The errors to be shown
        \\are filtered based on the given filter, which shall be provided with 
        \\the ID followed by suffix. The supported suffixes are "d" or 
        \\"driver" for filtering based on "driver" and "a" or "axis" for 
        \\filtering based on "axis". If no filter is provided, clear errors on 
        \\all drivers.
        ,
        .execute = &commands.show_errors.impl,
    });
    errdefer command.registry.orderedRemove("PRINT_ERRORS");
    try command.registry.put(.{
        .name = "STOP",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line", .optional = true },
        },
        .short_description = "Stop any operation on the line(s).",
        .long_description =
        \\Stop any currently running operation and remove any queued commands for
        \\the specified line. Not providing a line will stop the operation of
        \\entire system.
        ,
        .execute = &commands.stop.impl,
    });
    errdefer command.registry.orderedRemove("STOP");
    try command.registry.put(.{
        .name = "PAUSE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line", .optional = true },
        },
        .short_description = "Pause any operation on the line(s).",
        .long_description =
        \\Pause any currently running operation for the specified line. Not 
        \\providing a line will pause the operation of entire system.
        ,
        .execute = &commands.pause.impl,
    });
    errdefer command.registry.orderedRemove("PAUSE");
    try command.registry.put(.{
        .name = "RESUME",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line", .optional = true },
        },
        .short_description = "Resume the line(s) operation.",
        .long_description =
        \\Resume the specified line operation after being paused or stopped. Not
        \\providing a line will resume the operation of entire system.
        ,
        .execute = &commands.@"resume".impl,
    });
    errdefer command.registry.orderedRemove("RESUME");
    try command.registry.put(.{
        .name = "SET_CARRIER_ID",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line" },
            .{ .name = "carrier" },
            .{ .name = "new carrier id" },
        },
        .short_description = "Update carrier ID to a new one.",
        .long_description =
        \\Update an initialized carrier ID into a new one. The new carrier ID
        \\shall not be used by other carriers on the same line.
        ,
        .execute = &commands.set_carrier_id.impl,
    });
    errdefer command.registry.orderedRemove("SET_CARRIER_ID");
}

pub fn deinit() void {
    commands.disconnect.impl(&.{}) catch {};
    allocator.free(config.host);
    if (debug_allocator.detectLeaks()) {
        std.log.debug("Leaks detected", .{});
    } else {
        arena.deinit();
    }
    if (builtin.os.tag == .windows) std.os.windows.WSACleanup() catch return;
}

pub fn removeIgnoredMessage(socket: zignet.Socket) !void {
    if (try zignet.Socket.readyToRead(socket.fd, 0)) {
        _ = try reader.interface.peekByte();
    }
}

pub fn matchLine(name: []const u8) !usize {
    for (lines) |line| {
        if (std.mem.eql(u8, line.name, name)) return line.index;
    } else return error.LineNameNotFound;
}

/// Track a command until it executed completely followed by removing that
/// command from the server.
pub fn waitCommandReceived() !void {
    const socket = sock orelse return error.ServerNotConnected;
    const command_id = b: {
        // Receive response
        try socket.waitToRead(&command.checkCommandInterrupt);
        const decoded: api.protobuf.mmc.Response = try .decode(
            &reader.interface,
            allocator,
        );
        break :b switch (decoded.body orelse return error.InvalidResponse) {
            .request_error => |req_err| {
                return error_response.throwMmcError(req_err);
            },
            .command => |command_resp| switch (command_resp.body orelse
                return error.InvalidResponse) {
                .id => |id| id,
                .request_error => |req_err| {
                    return error_response.throwCommandError(req_err);
                },
                else => return error.InvalidResponse,
            },
            else => return error.InvalidResponse,
        };
    };
    defer removeCommand(command_id) catch {};
    while (true) {
        const request: api.protobuf.mmc.Request = .{
            .body = .{
                .info = .{
                    .body = .{
                        .command = .{ .id = command_id },
                    },
                },
            },
        };
        try removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        // Send message
        try request.encode(&writer.interface, allocator);
        try writer.interface.flush();
        // Receive response
        try socket.waitToRead(&command.checkCommandInterrupt);
        var decoded: api.protobuf.mmc.Response = try .decode(
            &reader.interface,
            allocator,
        );
        defer decoded.deinit(allocator);
        var commands_resp = switch (decoded.body orelse
            return error.InvalidResponse) {
            .request_error => |req_err| {
                return error_response.throwMmcError(req_err);
            },
            .info => |info_resp| switch (info_resp.body orelse
                return error.InvalidResponse) {
                .command => |commands_resp| commands_resp,
                .request_error => |req_err| {
                    return error_response.throwInfoError(req_err);
                },
                else => return error.InvalidResponse,
            },
            else => return error.InvalidResponse,
        };
        const comm = commands_resp.items.pop() orelse
            return error.InvalidResponse;
        switch (comm.status) {
            .COMMAND_STATUS_PROGRESSING => {}, // continue the loop
            .COMMAND_STATUS_COMPLETED => break,
            .COMMAND_STATUS_FAILED => {
                return switch (comm.@"error".?) {
                    .COMMAND_ERROR_INVALID_SYSTEM_STATE => error.InvalidSystemState,
                    .COMMAND_ERROR_DRIVER_DISCONNECTED => error.DriverDisconnected,
                    .COMMAND_ERROR_UNEXPECTED => error.Unexpected,
                    .COMMAND_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                    .COMMAND_ERROR_CONFLICTING_CARRIER_ID => error.ConflictingCarrierId,
                    .COMMAND_ERROR_CARRIER_ALREADY_INITIALIZED => error.CarrierAlreadyInitialized,
                    .COMMAND_ERROR_INVALID_CARRIER_TARGET => error.InvalidCarrierTarget,
                    .COMMAND_ERROR_DRIVER_STOPPED => error.DriverStopped,
                    else => error.UnexpectedResponse,
                };
            },
            else => return error.UnexpectedResponse,
        }
    }
}

fn removeCommand(id: u32) !void {
    const socket = sock orelse return error.ServerNotConnected;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .remove_command = .{ .command = id },
                },
            },
        },
    };
    try removeIgnoredMessage(socket);
    try socket.waitToWrite(&command.checkCommandInterrupt);
    // Send message
    try request.encode(&writer.interface, allocator);
    try writer.interface.flush();
    // Receive message
    try socket.waitToRead(&command.checkCommandInterrupt);
    const decoded: api.protobuf.mmc.Response = try .decode(
        &reader.interface,
        allocator,
    );
    const removed_id = switch (decoded.body orelse
        return error.InvalidResponse) {
        .command => |command_resp| switch (command_resp.body orelse
            return error.InvalidResponse) {
            .removed_id => |removed_id| removed_id,
            .request_error => |req_err| {
                return error_response.throwCommandError(req_err);
            },
            else => return error.InvalidResponse,
        },
        .request_error => |req_err| {
            return error_response.throwMmcError(req_err);
        },
        else => return error.InvalidResponse,
    };
    std.log.debug("removed_id {}, id {}", .{ removed_id, id });
}

pub fn nestedWrite(
    name: []const u8,
    val: anytype,
    indent: usize,
    w: *std.Io.Writer,
) !usize {
    var written_bytes: usize = 0;
    const ti = @typeInfo(@TypeOf(val));
    switch (ti) {
        .optional => {
            if (val) |v| {
                written_bytes += try nestedWrite(
                    name,
                    v,
                    indent,
                    w,
                );
            } else {
                try w.splatBytesAll("    ", indent);
                written_bytes += 4 * indent;
                try w.print("{s}: ", .{name});
                written_bytes += name.len + 2;
                try w.print("None,\n", .{});
                written_bytes += std.fmt.count("None,\n", .{});
            }
        },
        .@"struct" => {
            try w.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try w.print("{s}: {{\n", .{name});
            written_bytes += name.len + 4;
            inline for (ti.@"struct".fields) |field| {
                if (field.name[0] == '_') {
                    continue;
                }
                written_bytes += try nestedWrite(
                    field.name,
                    @field(val, field.name),
                    indent + 1,
                    w,
                );
            }
            try w.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try w.writeAll("},\n");
            written_bytes += 3;
        },
        .bool, .int => {
            try w.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try w.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try w.print("{},\n", .{val});
            written_bytes += std.fmt.count("{},\n", .{val});
        },
        .float => {
            try w.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try w.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try w.print("{d},\n", .{val});
            written_bytes += std.fmt.count("{d},\n", .{val});
        },
        .@"enum" => {
            try w.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try w.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try w.print("{t},\n", .{val});
            written_bytes += std.fmt.count("{t},\n", .{val});
        },
        .@"union" => {
            switch (val) {
                inline else => |_, tag| {
                    const union_val = @field(val, @tagName(tag));
                    try w.splatBytesAll("    ", indent);
                    written_bytes += 4 * indent;
                    try w.print("{s}: ", .{name});
                    written_bytes += name.len + 2;
                    try w.print("{d},\n", .{union_val});
                    written_bytes += std.fmt.count("{d},\n", .{union_val});
                },
            }
        },
        else => {
            error.InvalidValueType;
        },
    }
    return written_bytes;
}
