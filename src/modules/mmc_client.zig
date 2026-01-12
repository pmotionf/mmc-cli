const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");

const CircularBufferAlloc =
    @import("../circular_buffer.zig").CircularBufferAlloc;
const command = @import("../command.zig");
pub const Line = @import("mmc_client/Line.zig");
pub const log = @import("mmc_client/log.zig");
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

/// Stores standard units and min/max values for system
pub const Standard = struct {
    time: struct {
        unit_short: []const u8 = "ms",
        unit_long: []const u8 = "millisecond",
    } = .{},

    length: struct {
        unit_short: []const u8 = "mm",
        unit_long: []const u8 = "millimeter",
    } = .{},
    speed: struct {
        range: struct {
            min: u16 = 0,
            max: u16 = 6000,
        } = .{},
        unit: []const u8 = "mm/s",
    } = .{},
    acceleration: struct {
        range: struct {
            min: f32 = 0,
            max: f32 = 24_500,
        } = .{},
        unit: []const u8 = "mm/s²",
    } = .{},
};
const standard: Standard = .{};

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
            // cc_link_disconnected is currently not being used in the server.
            .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED,
            => error.InvalidResponse,
            .COMMAND_REQUEST_ERROR_INVALID_LOCATION => error.InvalidLocation,
            .COMMAND_REQUEST_ERROR_INVALID_DISTANCE => error.InvalidDistance,
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

    /// Invalidates original filter's allocated memory ownership.
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
/// The logging configuration is initialized once the client is connected, and
/// deinitialized if the client is disconnected.
pub var log_config: log.Config = undefined;
/// Currently connected socket. Nulled when disconnect.
pub var sock: ?zignet.Socket = null;
/// Currently saved endpoint. The endpoint will be overwritten if the client
/// is connected to a different server. Stays null before connected to a socket.
pub var endpoint: ?zignet.Endpoint = null;

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
    allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;
    config = .{
        .host = try allocator.dupe(u8, c.host),
        .port = c.port,
    };
    errdefer allocator.free(config.host);

    try command.registry.put(.{ .executable = .{
        .name = "SERVER_VERSION",
        .short_description = "Display the connected MMC server version.",
        .long_description =
        \\Display the version of the currently connected MMC server in Semantic
        \\Version format ({major}.{minor}.{patch}).
        ,
        .execute = &commands.server_version.impl,
    } });
    errdefer command.registry.orderedRemove("SERVER_VERSION");
    try command.registry.put(.{ .executable = .{
        .name = "CONNECT",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "endpoint", .optional = true },
        },
        .short_description = "Connect to MMC server.",
        .long_description = std.fmt.comptimePrint(
            \\Attempt to connect to MMC server.
            \\
            \\Endpoint may be specified using one of the following formats:
            \\ - `HOSTNAME:PORT`
            \\ - `IPv4_ADDRESS:PORT`
            \\ - `[IPv6_ADDRESS%SCOPE]:PORT`
            \\
            \\If no endpoint provided, last connected server is used. If no server has
            \\been connected since `LOAD_CONFIG`, connect to the default endpoint
            \\provided in the configuration file.
        , .{}),
        .execute = &commands.connect.impl,
    } });
    errdefer command.registry.orderedRemove("CONNECT");
    try command.registry.put(.{ .executable = .{
        .name = "DISCONNECT",
        .short_description = "End connection with MMC server.",
        .long_description = std.fmt.comptimePrint(
            \\Disconnect from currently connected MMC server.
        , .{}),
        .execute = &commands.disconnect.impl,
    } });
    errdefer command.registry.orderedRemove("DISCONNECT");
    try command.registry.put(.{
        .executable = .{
            .name = "SET_SPEED",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "speed" },
            },
            .short_description = "Set Carrier speed of specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Set Carrier speed of specified Line. The speed value must be
                \\greater than {d} and less than or equal to {d} {s}.
            , .{
                standard.speed.range.min,
                standard.speed.range.max,
                standard.speed.unit,
            }),
            .execute = &commands.set_speed.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_SPEED");
    try command.registry.put(.{
        .executable = .{
            .name = "SET_ACCELERATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "acceleration" },
            },
            .short_description = "Set Carrier acceleration of specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Set Carrier acceleration of specified Line. The acceleration value
                \\must be greater than {d} and less than or equal to {d} {s}.
            , .{
                standard.acceleration.range.min,
                standard.acceleration.range.max,
                standard.acceleration.unit,
            }),
            .execute = &commands.set_acceleration.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_ACCELERATION");
    try command.registry.put(.{
        .executable = .{
            .name = "GET_SPEED",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
            },
            .short_description = "Print Carrier speed of the specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier speed of specified Line.
            , .{}),
            .execute = &commands.get_speed.impl,
        },
    });
    errdefer command.registry.orderedRemove("GET_SPEED");
    try command.registry.put(.{
        .executable = .{
            .name = "GET_ACCELERATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
            },
            .short_description = "Print Carrier acceleration of the specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier acceleration of the specified Line.
            , .{}),
            .execute = &commands.get_acceleration.impl,
        },
    });
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_AXIS_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter" },
            },
            .short_description = "Print Axis information.",
            .long_description = std.fmt.comptimePrint(
                \\Print Axis information of specified Line. Specify which Axis or Axes
                \\to print info via filter. To apply filter, provide ID with filter
                \\suffix (e.g., 1a). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.print_axis_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_AXIS_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_DRIVER_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter" },
            },
            .short_description = "Print Driver information.",
            .long_description = std.fmt.comptimePrint(
                \\Print Driver information of specified Line. Specify which Driver to
                \\print info via filter. To apply filter, provide ID with filter suffix
                \\(e.g., 1d). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.print_driver_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_DRIVER_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_CARRIER_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Print Carrier information.",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier information of specified Line.
                \\Optional: Provide filter to specify selection of Carrier(s). To apply
                \\filter, provide ID with filter suffix (e.g., 1c). Supported suffixes
                \\are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.print_carrier_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_CARRIER_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "AXIS_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{
                    .name = "result variable",
                    .optional = true,
                    .resolve = false,
                },
            },
            .short_description = "Print Carrier information on Axis, if exists.",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier information on Axis, if exists. Information only provided
                \\when:
                \\ - Carrier is on specified Axis.
                \\ - Carrier is initialized
                \\
                \\Optional: Store Carrier ID in provided variable. Variable cannot start
                \\with a number and is case sensitive.
            , .{}),
            .execute = &commands.axis_carrier.impl,
        },
    });
    errdefer _ = command.registry.orderedRemove("AXIS_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_ID",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line(s)" },
                .{
                    .name = "result variable prefix",
                    .optional = true,
                    .resolve = false,
                },
            },
            .short_description = "Display Carrier IDs on Line.",
            .long_description = std.fmt.comptimePrint(
                \\Display Carrier IDs on Line. Scans specified Line(s), starting from
                \\first Axis. Carrier IDs are provided in order of occurrence. Multi Line
                \\input possible (e.g., line1,line2,line3).
                \\Optional: Stores Carrier IDs in provided variable as indexed entries
                \\(e.g., var1, var2, ...). Variable cannot start with a number and is
                \\case sensitive.
            , .{}),
            .execute = &commands.carrier_id.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_ID");
    try command.registry.put(.{
        .executable = .{
            .name = "ASSERT_CARRIER_LOCATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Carrier" },
                .{ .name = "location" },
                .{ .name = "threshold", .optional = true },
            },
            .short_description = "Assert Carrier location.",
            .long_description = std.fmt.comptimePrint(
                \\Assert Carrier location. Error if Carrier is not at specified location.
                \\Optional: Provide threshold to change default location threshold value.
                \\Default location threshold value is 1 {s}. Location and threshold must
                \\be provided in {s}.
            , .{
                standard.length.unit_short,
                standard.length.unit_long,
            }),
            .execute = &commands.assert_location.impl,
        },
    });
    errdefer command.registry.orderedRemove("ASSERT_CARRIER_LOCATION");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_LOCATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Carrier" },
                .{
                    .name = "result variable",
                    .resolve = false,
                    .optional = true,
                },
            },
            .short_description = "Display Carrier location, if exists.",
            .long_description = std.fmt.comptimePrint(
                \\Display location of Carrier on specified Line, if exists.
                \\Optional: Store Carrier location in variable. Variable cannot start
                \\with a number and is case sensitive.
            , .{}),
            .execute = &commands.carrier_location.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_LOCATION");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_AXIS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Carrier" },
            },
            .short_description = "Display Carrier Axis",
            .long_description = std.fmt.comptimePrint(
                \\Display Axis on which Carrier is currently.
            , .{}),
            .execute = &commands.carrier_axis.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_AXIS");
    try command.registry.put(.{
        .executable = .{
            .name = "HALL_STATUS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Display Hall Sensor state.",
            .long_description = std.fmt.comptimePrint(
                \\Display Hall Sensor status.
                \\Optional: Provide filter to specify selection of Hall Sensor(s). To
                \\apply filter, provide ID with filter suffix (e.g., 1a).Supported
                \\suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.hall_status.impl,
        },
    });
    errdefer command.registry.orderedRemove("HALL_STATUS");
    try command.registry.put(.{
        .executable = .{
            .name = "ASSERT_HALL",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "side" },
                .{ .name = "on/off", .optional = true },
            },
            .short_description = "Assert Hall Sensor state.",
            .long_description = std.fmt.comptimePrint(
                \\Assert if Hall Sensor is in expected state. Hall Sensor location must
                \\be provided, as:
                \\ - front (direction of increasing Axis number)
                \\ - back  (direction of decreasing Axis number)
                \\
                \\Hall Sensor state provided, as:
                \\ - on  (Hall Sensor indicator "on")
                \\ - off (Hall Sensor indicator "off")
                \\ - default state if not provided as "on"
            , .{}),
            .execute = &commands.assert_hall.impl,
        },
    });
    errdefer command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put(.{
        .executable = .{
            .name = "CLEAR_ERRORS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Clear error states.",
            .long_description = std.fmt.comptimePrint(
                \\Clear error states on all Driver(s) of specified Line.
                \\Optional: Provide filter to specify Driver. To apply filter, provide
                \\ID with filter suffix (e.g., 1d). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.clear_errors.impl,
        },
    });
    errdefer command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(.{
        .executable = .{
            .name = "DEINITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Deinitialize Carrier.",
            .long_description = std.fmt.comptimePrint(
                \\Deinitialize Carrier on specified Line.
                \\Optional: Provide filter to specify selection of Carrier(s). To apply
                \\filter, provide ID with filter suffix (e.g., 1c). Supported suffixes
                \\are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.clear_carrier_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("DEINITIALIZE");
    try command.registry.put(.{ .alias = .{
        .name = "CLEAR_CARRIER_INFO",
        .command = command.registry.getPtr("DEINITIALIZE").?,
    } });
    errdefer command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "RESET_SYSTEM",
        .short_description = "Reset system state.",
        .long_description = std.fmt.comptimePrint(
            \\Reset system:
            \\ - Deinitialize all Carriers.
            \\ - Clear all system errors.
            \\ - Reset all push and pull states.
        , .{}),
        .execute = &commands.reset_system.impl,
    } });
    errdefer command.registry.orderedRemove("RESET_SYSTEM");
    try command.registry.put(.{
        .executable = .{
            .name = "RELEASE_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Release Carrier",
            .long_description = std.fmt.comptimePrint(
                \\Release Carrier, allows to move Carrier through external force. Carrier
                \\stays initialized.
                \\Optional: Provide filter to specify selection of Carrier(s). To apply
                \\filter, provide ID with filter suffix (e.g., 1c). Supported suffixes
                \\are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.release_carrier.impl,
        },
    });
    errdefer command.registry.orderedRemove("RELEASE_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "AUTO_INITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line(s)", .optional = true },
            },
            .short_description = "Initialize all Carriers automatically.",
            .long_description = std.fmt.comptimePrint(
                \\Automatically initializes all uninitialized Carriers. This process
                \\operates on carrier clusters, where a cluster is defined as a group of
                \\uninitialized Carriers located on adjacent Axis. Each cluster requires
                \\at least one free Axis to successfully initialize cluster. Multiple
                \\Line auto initialization is supported (e.g., line1,line2,line3). If
                \\Line is not provided, auto initializes Carriers on all Lines.
            , .{}),
            .execute = &commands.auto_initialize.impl,
        },
    });
    errdefer command.registry.orderedRemove("AUTO_INITIALIZE");
    try command.registry.put(.{
        .executable = .{
            .name = "CALIBRATE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
            },
            .short_description = "Calibrate Track Line.",
            .long_description = std.fmt.comptimePrint(
                \\Calibrate Track Line. Uninitialized Carrier must be positioned at start
                \\of Line and first Axis Hall Sensors are both in "on" state.
            , .{}),
            .execute = &commands.calibrate.impl,
        },
    });
    errdefer command.registry.orderedRemove("CALIBRATE");
    try command.registry.put(.{
        .executable = .{
            .name = "SET_ZERO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
            },
            .short_description = "Set Line zero position.",
            .long_description = std.fmt.comptimePrint(
                \\Set zero position for specified Line. Initialized Carrier must be on
                \\first Axis of specified Line.
            , .{}),
            .execute = &commands.set_line_zero.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_ZERO");
    try command.registry.put(.{
        .alias = .{
            .name = "SET_LINE_ZERO",
            .command = command.registry.getPtr("SET_ZERO").?,
        },
    });
    errdefer command.registry.orderedRemove("SET_LINE_ZERO");
    try command.registry.put(.{
        .executable = .{
            .name = "INITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "direction" },
                .{ .name = "Carrier" },
                .{ .name = "link Axis", .resolve = false, .optional = true },
            },
            .short_description = "Initialize Carrier.",
            .long_description = std.fmt.comptimePrint(
                \\Slowly moves an uninitialized Carrier to the next Hall Sensor in the
                \\provided direction, and assign provided Carrier ID to the Carrier.
                \\Direction options:
                \\ - forward  (direction of increasing Axis number)
                \\ - backward (direction of decreasing Axis number)
                \\
                \\Optional: Provide link Axis if the uninitialized Carrier is located
                \\between two Axis. Link Axis options:
                \\ - next  (direction of increasing Axis number)
                \\ - prev  (direction of decreasing Axis number)
                \\ - right (direction of increasing Axis number)
                \\ - left  (direction of decreasing Axis number)
            , .{}),
            .execute = &commands.isolate.impl,
        },
    });
    errdefer command.registry.orderedRemove("INITIALIZE");
    try command.registry.put(.{ .alias = .{
        .name = "ISOLATE",
        .command = command.registry.getPtr("INITIALIZE").?,
    } });
    errdefer command.registry.orderedRemove("ISOLATE");
    try command.registry.put(.{ .executable = .{
        .name = "WAIT_INITIALIZE",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line" },
            .{ .name = "Carrier" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait until Carrier initialization complete.",
        .long_description = std.fmt.comptimePrint(
            \\Pauses command execution until specified Carrier completes initialization.
            \\Optional: Provide timeout. Returns error if specified timeout is exceeded.
            \\Timeout must be provided in {s}.
        , .{standard.time.unit_long}),
        .execute = &commands.wait.isolate,
    } });
    errdefer command.registry.orderedRemove("WAIT_INITIALIZE");
    try command.registry.put(.{ .alias = .{
        .name = "WAIT_ISOLATE",
        .command = command.registry.getPtr("WAIT_INITIALIZE").?,
    } });
    errdefer command.registry.orderedRemove("WAIT_ISOLATE");
    try command.registry.put(.{
        .executable = .{
            .name = "WAIT_MOVE_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Carrier" },
                .{ .name = "timeout", .optional = true },
            },
            .short_description = "Wait until Carrier movement complete.",
            .long_description = std.fmt.comptimePrint(
                \\Pauses command execution until specified Carrier completes movement.
                \\Optional: Provide timeout. Returns error if specified timeout is
                \\exceeded. Timeout must be provided in {s}.
            , .{standard.time.unit_long}),
            .execute = &commands.wait.moveCarrier,
        },
    });
    errdefer command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "MOVE_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line" },
            .{ .name = "Carrier" },
            .{ .name = "target" },
            .{ .name = "disable cas", .optional = true },
            .{ .name = "control mode", .optional = true },
        },
        .short_description = "Move Carrier to specified target.",
        .long_description = std.fmt.comptimePrint(
            \\Move initialized Carrier to specified target. Provide target value
            \\followed by suffix to specify target movement (e.g., 1a). Supported
            \\suffixes are:
            \\- "a" or "axis" to target Axis.
            \\- "l" or "location" to target absolute location in Line, provided in
            \\  {s}.
            \\- "d" or "distance" to target relative distance to current Carrier
            \\  position, provided in {s}.
            \\Optional: Provide "true" to disable CAS (Collision Avoidance System).
            \\Optional: Provide followings to specify movement control mode:
            \\- "speed" to move Carrier with speed profile feedback.
            \\- "position" to move Carrier with position profile feedback.
        , .{ standard.length.unit_short, standard.length.unit_short }),
        .execute = &commands.move.impl,
    } });
    errdefer command.registry.orderedRemove("MOVE_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "PUSH_CARRIER_FORWARD",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "Carrier", .optional = true },
            },
            .short_description = "Push Carrier forward to specified Axis.",
            .long_description = std.fmt.comptimePrint(
                \\Push a Carrier on the specified Axis forward. This movement targets a
                \\distance of the Carrier length, and thus if it is used to cross a Line
                \\boundary, the receiving Axis at the destination Line must first be
                \\pulling the Carrier.
                \\Optional: Provide Carrier to move the specified Carrier to the center
                \\of the specified Axis, then push forward.
            , .{}),
            .execute = &commands.push.forward,
        },
    });
    try command.registry.put(.{
        .executable = .{
            .name = "PUSH_CARRIER_BACKWARD",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "Carrier", .optional = true },
            },
            .short_description = "Push Carrier backward to specified Axis.",
            .long_description = std.fmt.comptimePrint(
                \\Push a Carrier on the specified Axis backward. This movement targets a
                \\distance of the Carrier length, and thus if it is used to cross a Line
                \\boundary, the receiving Axis at the destination Line must first be
                \\pulling the Carrier.
                \\Optional: Provide Carrier to move the specified Carrier to the center
                \\of the specified Axis, then push forward.
            , .{}),
            .execute = &commands.push.backward,
        },
    });
    errdefer command.registry.orderedRemove("PUSH_CARRIER_BACKWARD");
    try command.registry.put(.{
        .executable = .{
            .name = "PULL_CARRIER_FORWARD",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "Carrier" },
                .{ .name = "location", .optional = true },
                .{ .name = "disable CAS", .optional = true },
            },
            .short_description = "Pull incoming Carrier forward.",
            .long_description = std.fmt.comptimePrint(
                \\Initialize and move incoming carrier forward to specified Axis. Assign
                \\the specified Carrier ID for pulled Carrier. There must be no carrier
                \\on pulling axis.
                \\Optional: Provide location to move carrier after completed pulling
                \\Carrier. Location must be provided as:
                \\- {s} (move Carrier to specified location after pulled to specified
                \\  axis) or
                \\- "nan" (Carrier can move through external force after pulled to
                \\  specified axis )
                \\Optional: Provide "true" to disable CAS (Collision Avoidance System)
                \\while Carrier is moved to location.
            , .{
                standard.length.unit_long,
            }),
            .execute = &commands.pull.forward,
        },
    });
    errdefer command.registry.orderedRemove("PULL_CARRIER_FORWARD");
    try command.registry.put(.{
        .executable = .{
            .name = "PULL_CARRIER_BACKWARD",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Axis" },
                .{ .name = "Carrier" },
                .{ .name = "location", .optional = true },
                .{ .name = "disable CAS", .optional = true },
            },
            .short_description = "Pull incoming Carrier backward.",
            .long_description = std.fmt.comptimePrint(
                \\Initialize and move incoming carrier backward to specified Axis. Assign
                \\the specified Carrier ID for pulled Carrier. There must be no carrier
                \\on pulling axis.
                \\Optional: Provide location to move carrier after completed pulling
                \\Carrier. Location must be provided as:
                \\- {s} (move Carrier to specified location after pulled to specified
                \\  axis) or
                \\- "nan" (Carrier can move through external force after pulled to
                \\  specified axis )
                \\
                \\Optional: Provide "true" to disable CAS (Collision Avoidance System).
                \\while Carrier is moved to location.
            , .{
                standard.length.unit_long,
            }),
            .execute = &commands.pull.backward,
        },
    });
    errdefer command.registry.orderedRemove("PULL_CARRIER_BACKWARD");
    try command.registry.put(.{ .executable = .{
        .name = "STOP_PULL_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Stop pulling Carrier at axis.",
        .long_description = std.fmt.comptimePrint(
            \\Stop active Carrier pull of specified Line.
            \\Optional: Provide filter to specify selection of pull. To apply filter,
            \\provide ID with filter suffix (e.g., 1c). Supported suffixes are:
            \\ - "a" or "axis" to filter by Axis
            \\ - "c" or "Carrier" to filter by Carrier
            \\ - "d" or "driver" to filter by Driver
        , .{}),
        .execute = &commands.stop_pull.impl,
    } });
    errdefer command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "STOP_PUSH_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "filter", .optional = true },
            },
            .short_description = "Stop pushing Carrier at axis.",
            .long_description = std.fmt.comptimePrint(
                \\Stop active Carrier push on specified Line.
                \\Optional: Provide filter to specify selection of push. To apply
                \\filter, provide ID with filter suffix (e.g., 1c).
                \\Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "Carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
            , .{}),
            .execute = &commands.stop_push.impl,
        },
    });
    errdefer command.registry.orderedRemove("STOP_PUSH_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "WAIT_AXIS_EMPTY",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line" },
            .{ .name = "Axis" },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait until no Carrier on Axis.",
        .long_description = std.fmt.comptimePrint(
            \\Pause execution of commands until specified Axis has:
            \\ - no carriers,
            \\ - no active hall alarms,
            \\ - no wait for push/pull.
            \\Optional: timeout will return error if timeout duration is exceeded.
            \\Timeout duration must be provided in {s}.
        , .{
            standard.time.unit_long,
        }),
        .execute = &commands.wait.axisEmpty,
    } });
    errdefer command.registry.orderedRemove("WAIT_AXIS_EMPTY");
    try command.registry.put(.{
        .executable = .{
            .name = "ADD_LOG_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "kind" },
                .{ .name = "range", .optional = true },
            },
            .short_description = "Add logging configuration.",
            .long_description = std.fmt.comptimePrint(
                \\Add logging configuration. Overwrites existing logging configuration
                \\of specified Line. Parameter "kind" specifies information to add to
                \\logging configuration. Valid "kind" options:
                \\ - driver
                \\ - axis
                \\ - all
                \\
                \\Optional: "range" defines Axis range and must be provided as
                \\start:end value (e.g., "1:9").
            , .{}),
            .execute = &commands.log.add,
        },
    });
    errdefer command.registry.orderedRemove("ADD_LOG_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "START_LOG_INFO",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "duration" },
            .{ .name = "path", .optional = true },
        },
        .short_description = "Start logging.",
        .long_description = std.fmt.comptimePrint(
            \\Start logging process. Log file contains only recent data during specified
            \\time (in seconds). Logging runs until:
            \\ - error occurs or
            \\ - cancelled by "STOP_LOGGING" command.
            \\
            \\If path not specified, log file will be created in working directory:
            \\ - "mmc-logging-YYYY.MM.DD-HH.MM.SS.csv".
        , .{}),
        .execute = &commands.log.start,
    } });
    errdefer command.registry.orderedRemove("START_LOG_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "REMOVE_LOG_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "kind" },
                .{ .name = "range", .optional = true },
            },
            .short_description = "Remove logging configuration.",
            .long_description = std.fmt.comptimePrint(
                \\Remove logging configuration. Parameter "kind" specifies information to
                \\remove from logging configuration. Valid "kind" options:
                \\ - driver
                \\ - axis
                \\ - all
                \\
                \\Optional: "range" defines Axis range and must be provided as start:end
                \\value (e.g., "1:9").
            , .{}),
            .execute = &commands.log.remove,
        },
    });
    errdefer command.registry.orderedRemove("REMOVE_LOG_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "STATUS_LOG_INFO",
        .short_description = "Show logging configuration.",
        .long_description = std.fmt.comptimePrint(
            \\Show logging configuration for specified Line(s).
        , .{}),
        .execute = &commands.log.status,
    } });
    errdefer command.registry.orderedRemove("STATUS_LOG_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "STOP_LOG_INFO",
        .short_description = "Stop MMC logging.",
        .long_description = std.fmt.comptimePrint(
            \\Stop MMC logging and save logging data to file.
        , .{}),
        .execute = &commands.log.stop,
    } });
    errdefer command.registry.orderedRemove("STOP_LOG_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "CANCEL_LOG_INFO",
        .short_description = "Cancel MMC logging process.",
        .long_description = std.fmt.comptimePrint(
            \\Cancel MMC logging without saving the logging data.
        , .{}),
        .execute = &commands.log.cancel,
    } });
    errdefer command.registry.orderedRemove("CANCEL_LOG_INFO");
    try command.registry.put(.{ .executable = .{
        .name = "PRINT_ERRORS",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line" },
            .{ .name = "filter", .optional = true },
        },
        .short_description = "Print Axis and Driver errors.",
        .long_description = std.fmt.comptimePrint(
            \\Print Axis and Driver errors on specified Line.
            \\Optional: Provide filter to specify selection of error(s). To apply filter,
            \\provide ID with filter suffix (e.g., 1a). Supported suffixes are:
            \\ - "a" or "axis" to filter by Axis
            \\ - "c" or "Carrier" to filter by Carrier
            \\ - "d" or "driver" to filter by Driver
        , .{}),
        .execute = &commands.show_errors.impl,
    } });
    errdefer command.registry.orderedRemove("PRINT_ERRORS");
    try command.registry.put(.{ .executable = .{
        .name = "STOP",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .optional = true },
        },
        .short_description = "Stop all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Stop all running and queued processes on System.
            \\Optional: Stop all running and queued processes only on specified Line.
        , .{}),
        .execute = &commands.stop.impl,
    } });
    errdefer command.registry.orderedRemove("STOP");
    try command.registry.put(.{
        .executable = .{
            .name = "PAUSE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .optional = true },
            },
            .short_description = "Pause all processes.",
            .long_description = std.fmt.comptimePrint(
                \\Pause all processes on System.
                \\Optional: Pause all processes only on specified Line.
            , .{}),
            .execute = &commands.pause.impl,
        },
    });
    errdefer command.registry.orderedRemove("PAUSE");
    try command.registry.put(.{
        .executable = .{
            .name = "RESUME",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .optional = true },
            },
            .short_description = "Resume all paused processes.",
            .long_description = std.fmt.comptimePrint(
                \\Resume all paused processes on System.
                \\Optional: Resume all paused processes only on specified Line.
            , .{}),
            .execute = &commands.@"resume".impl,
        },
    });
    errdefer command.registry.orderedRemove("RESUME");
    try command.registry.put(.{
        .executable = .{
            .name = "SET_CARRIER_ID",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line" },
                .{ .name = "Carrier" },
                .{ .name = "new Carrier id" },
            },
            .short_description = "Modify Carrier ID.",
            .long_description = std.fmt.comptimePrint(
                \\Modify Carrier ID of initialized Carrier. Carrier ID must be unique per
                \\Line.
            , .{}),
            .execute = &commands.set_carrier_id.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_CARRIER_ID");
}

pub fn deinit() void {
    commands.disconnect.impl(&.{}) catch {};
    allocator.free(config.host);
    if (debug_allocator.detectLeaks()) {
        std.log.debug("Leaks detected", .{});
    }
    if (builtin.os.tag == .windows) std.os.windows.WSACleanup() catch return;
}

pub fn matchLine(name: []const u8) !usize {
    for (lines) |line| {
        if (std.mem.eql(u8, line.name, name)) return line.index;
    } else return error.LineNameNotFound;
}

/// Track a command until it executed completely followed by removing that
/// command from the server.
pub fn waitCommandReceived() !void {
    if (sock == null) return error.ServerNotConnected;
    const command_id = b: {
        // Receive response
        while (true) {
            try command.checkCommandInterrupt();
            const byte = reader.interface.peekByte() catch |e| {
                switch (e) {
                    std.Io.Reader.Error.EndOfStream => continue,
                    std.Io.Reader.Error.ReadFailed => {
                        return reader.error_state orelse error.Unexpected;
                    },
                }
            };
            if (byte > 0) break;
        }
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
        // Clear all buffer in reader and writer for safety.
        _ = try reader.interface.discardRemaining();
        _ = writer.interface.consumeAll();
        // Send message
        try request.encode(&writer.interface, allocator);
        try writer.interface.flush();
        // Receive response
        while (true) {
            try command.checkCommandInterrupt();
            const byte = reader.interface.peekByte() catch |e| {
                switch (e) {
                    std.Io.Reader.Error.EndOfStream => continue,
                    std.Io.Reader.Error.ReadFailed => {
                        return reader.error_state orelse error.Unexpected;
                    },
                }
            };
            if (byte > 0) break;
        }
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
    if (sock == null) return error.ServerNotConnected;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .remove_command = .{ .command = id },
                },
            },
        },
    };
    // Clear all buffer in reader and writer for safety.
    _ = try reader.interface.discardRemaining();
    _ = writer.interface.consumeAll();
    // Send message
    try request.encode(&writer.interface, allocator);
    try writer.interface.flush();
    // Receive message
    while (true) {
        try command.checkCommandInterrupt();
        const byte = reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return reader.error_state orelse error.Unexpected;
                },
            }
        };
        if (byte > 0) break;
    }
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
