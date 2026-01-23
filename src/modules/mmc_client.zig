const std = @import("std");
const builtin = @import("builtin");

const chrono = @import("chrono");

const CircularBufferAlloc =
    @import("../circular_buffer.zig").CircularBufferAlloc;
const command = @import("../command.zig");
pub const Line = @import("mmc_client/Line.zig");
pub const log = @import("mmc_client/log.zig");
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
pub var parameter: Parameter = undefined;

// TODO: Support auto completion
/// Parameter parsing rules. Use `isValid()` function to check if value of
/// parameter kind is valid.
pub const Parameter = struct {
    /// Store every parameter's possible value. Not intended to be accessed directly. Use Parameter's function as the interface for parameter value.
    value: struct {
        line: LineName,
        axis: struct {
            fn isValid(_: *@This(), input: []const u8) bool {
                const axis = std.fmt.parseUnsigned(u32, input, 0) catch
                    return false;
                return (axis > 0 and axis <= Line.max_axis);
            }
        },
        carrier: struct {
            fn isValid(_: *@This(), input: []const u8) bool {
                const carrier = std.fmt.parseUnsigned(u32, input, 0) catch
                    return false;
                std.log.debug("valid: {}", .{carrier > 0 and carrier <= Line.max_axis});
                if (carrier > 0 and carrier <= Line.max_axis) return true;
                return false;
            }
        },
        direction: Direction,
        cas: Cas,
        link_axis: LinkAxis,
        variable: struct {
            fn isValid(_: *@This(), input: []const u8) bool {
                return std.ascii.isAlphabetic(input[0]);
            }
        },
        hall_state: hall.State,
        hall_side: hall.Side,
        filter: struct {
            fn isValid(_: *@This(), input: []const u8) bool {
                var suffix_idx: usize = 0;
                for (input) |c| {
                    if (std.ascii.isDigit(c)) suffix_idx += 1 else break;
                }
                // No digit is recognized.
                if (suffix_idx == 0) return false;

                const id = std.fmt.parseUnsigned(
                    u32,
                    input[0..suffix_idx],
                    0,
                ) catch return false; // Invalid ID
                // Check for single character suffix.
                if (input.len - suffix_idx == 1) {
                    if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "a") or
                        std.ascii.eqlIgnoreCase(input[suffix_idx..], "c"))
                        return (id > 0 and id <= Line.max_axis)
                    else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "d"))
                        return (id > 0 and id <= Line.max_driver)
                    else
                        return false;
                }
                // Check for `axis` suffix
                else if (input.len - suffix_idx == 4 and
                    std.ascii.eqlIgnoreCase(input[suffix_idx..], "axis"))
                    return (id > 0 and id <= Line.max_axis)
                    // Check for `carrier` suffix
                else if (std.ascii.eqlIgnoreCase(
                    input[suffix_idx..],
                    "carrier",
                ))
                    return (id > 0 and id <= Line.max_axis)
                    // Check for `driver` suffix
                else if (input.len - suffix_idx == 6 and
                    std.ascii.eqlIgnoreCase(input[suffix_idx..], "driver"))
                    return (id > 0 and id <= Line.max_driver)
                else
                    return false;
            }
        },
        control_mode: Control,
        target: struct {
            fn isValid(_: *@This(), input: []const u8) bool {
                var suffix_idx: usize = 0;
                for (input) |c| {
                    if (std.ascii.isAlphabetic(c)) break else suffix_idx += 1;
                }
                // No digit is recognized.
                if (suffix_idx == 0) return false;
                // Check for single character suffix.
                if (input.len - suffix_idx == 1) {
                    if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "a")) {
                        const axis = std.fmt.parseUnsigned(
                            u32,
                            input[0..suffix_idx],
                            0,
                        ) catch return false;
                        return (axis > 0 and axis <= Line.max_axis);
                    } else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "l")) {
                        _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                            return false;
                        return true;
                    } else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "d")) {
                        _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                            return false;
                        return true;
                    }
                    return false;
                }
                // Check for `axis` suffix
                else if (input.len - suffix_idx == 4 and
                    std.ascii.eqlIgnoreCase(input[suffix_idx..], "axis"))
                {
                    const axis = std.fmt.parseUnsigned(
                        u32,
                        input[0..suffix_idx],
                        0,
                    ) catch return false;
                    return (axis > 0 and axis <= Line.max_axis);
                }
                // Check for `location` suffix
                else if (input.len - suffix_idx == 8 and
                    std.ascii.eqlIgnoreCase(input[suffix_idx..], "location"))
                {
                    _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                        return false;
                    return true;
                }
                // Check for `distance` suffix
                else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "distance")) {
                    _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                        return false;
                    return true;
                } else return false;
            }
        },
        log_kind: LogKind,

        const LineName = struct {
            items: std.BufSet,

            /// Create a bufset for storing recognized line names of connected
            /// server.
            fn init(a: std.mem.Allocator) @This() {
                return .{ .items = std.BufSet.init(a) };
            }

            /// Free stored line names and invalidate the field.
            fn deinit(self: *@This()) void {
                self.items.deinit();
                self.* = undefined;
            }

            // Remove all stored lines without invalidating the field.
            fn reset(self: *@This()) void {
                var it = self.items.hash_map.iterator();
                while (it.next()) |items| {
                    self.items.remove(items.key_ptr.*);
                }
                std.debug.assert(self.items.count() == 0);
            }

            /// Assert the parameter is a valid line name
            fn isValid(self: *@This(), input: []const u8) bool {
                // Invalidate if not connected to server.
                if (builtin.is_test == false and stream == null) return false;
                var it = std.mem.tokenizeSequence(u8, input, ",");
                while (it.next()) |item| {
                    if (self.items.contains(item) == false) return false;
                }
                return true;
            }
        };

        const Direction = enum {
            forward,
            backward,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };

        const Cas = enum {
            on,
            off,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };

        const LinkAxis = enum {
            next,
            prev,
            right,
            left,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };

        const hall = struct {
            const State = enum {
                on,
                off,

                fn isValid(_: *@This(), input: []const u8) bool {
                    const ti = @typeInfo(@This()).@"enum";
                    inline for (ti.fields) |field| {
                        if (std.mem.eql(u8, field.name, input)) return true;
                    }
                    return false;
                }
            };

            const Side = enum {
                front,
                back,

                fn isValid(_: *@This(), input: []const u8) bool {
                    const ti = @typeInfo(@This()).@"enum";
                    inline for (ti.fields) |field| {
                        if (std.mem.eql(u8, field.name, input)) return true;
                    }
                    return false;
                }
            };
        };

        const Control = enum {
            speed,
            position,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };

        const LogKind = enum {
            axis,
            driver,
            all,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };
    },

    pub const Kind = enum {
        line,
        axis,
        carrier,
        direction,
        cas,
        link_axis,
        variable,
        hall_state,
        hall_side,
        filter,
        control_mode,
        target,
        log_kind,
    };
    /// Initialize required memory for storing runtime-known variables. Zero
    /// value initialization for comptime-known variables.
    pub fn init(a: std.mem.Allocator) @This() {
        var res: @This() = .{
            .value = std.mem.zeroInit(
                @FieldType(Parameter, "value"),
                .{ .line = .{undefined} },
            ),
        };
        // If a field has init function, invoke init function.
        inline for (@typeInfo(@TypeOf(res.value)).@"struct".fields) |field| {
            if (@hasDecl(field.type, "init")) {
                @field(res.value, field.name) = field.type.init(a);
            }
        }
        return res;
    }

    /// Free all stored runtime-known parameters and invalidate parameter.
    pub fn deinit(self: *@This()) void {
        inline for (@typeInfo(@TypeOf(self.value)).@"struct".fields) |field| {
            if (@hasDecl(field.type, "deinit")) {
                @field(self.value, field.name).deinit();
            }
        }
        self.* = undefined;
    }

    /// Check if the input is valid for the given kind.
    pub fn isValid(self: *@This(), kind: Kind, input: []const u8) bool {
        return switch (kind) {
            inline else => |tag| @field(self.value, @tagName(tag)).isValid(input),
        };
    }

    /// Free all stored runtime-known parameters without invalidating the field.
    pub fn reset(self: *@This()) void {
        inline for (@typeInfo(@TypeOf(self.value)).@"struct".fields) |field| {
            if (@hasDecl(field.type, "reset")) {
                @field(self.value, field.name).reset();
            }
        }
    }

    test "Parameter `Kind` and `value` matching" {
        const ValueType = @FieldType(Parameter, "value");
        // Check if every value fields has representation in Kind.
        inline for (@typeInfo(Parameter.Kind).@"enum".fields) |field| {
            try std.testing.expect(@hasField(ValueType, field.name));
        }
        // Check if every value`s fields have representation in Kind.
        inline for (@typeInfo(ValueType).@"struct".fields) |field| {
            try std.testing.expect(@hasField(Parameter.Kind, field.name));
        }
    }

    test isValid {
        var res: Parameter = .init(std.testing.allocator);
        defer res.deinit();
        // Validate line names
        try res.value.line.items.insert("left");
        try res.value.line.items.insert("right");
        try std.testing.expect(res.isValid(.line, "left"));
        try std.testing.expect(res.isValid(.line, "right"));
        try std.testing.expect(res.isValid(.line, "left,right"));
        try std.testing.expect(res.isValid(.line, "right,left"));
        try std.testing.expect(res.isValid(.line, "leftt") == false);
        // Validate axis
        try std.testing.expect(res.isValid(.axis, "768"));
        try std.testing.expect(res.isValid(.axis, "0") == false);
        try std.testing.expect(res.isValid(.axis, "769") == false);
        // Validate carrier
        try std.testing.expect(res.isValid(.carrier, "768"));
        try std.testing.expect(res.isValid(.carrier, "0") == false);
        try std.testing.expect(res.isValid(.carrier, "769") == false);
        // Validate direction
        try std.testing.expect(res.isValid(.direction, "forward"));
        try std.testing.expect(res.isValid(.direction, "backward"));
        try std.testing.expect(res.isValid(.direction, "769") == false);
        // Validate CAS
        try std.testing.expect(res.isValid(.cas, "on"));
        try std.testing.expect(res.isValid(.cas, "off"));
        try std.testing.expect(res.isValid(.cas, "forward") == false);
        // Validate link axis
        try std.testing.expect(res.isValid(.link_axis, "next"));
        try std.testing.expect(res.isValid(.link_axis, "prev"));
        try std.testing.expect(res.isValid(.link_axis, "left"));
        try std.testing.expect(res.isValid(.link_axis, "right"));
        try std.testing.expect(res.isValid(.link_axis, "forward") == false);
        // Validate variable
        try std.testing.expect(res.isValid(.variable, "next"));
        try std.testing.expect(res.isValid(.variable, "var"));
        try std.testing.expect(res.isValid(.variable, "c"));
        try std.testing.expect(res.isValid(.variable, "carrier"));
        try std.testing.expect(res.isValid(.variable, "1c") == false);
        // Validate hall state
        try std.testing.expect(res.isValid(.hall_state, "on"));
        try std.testing.expect(res.isValid(.hall_state, "off"));
        try std.testing.expect(res.isValid(.hall_state, "forward") == false);
        // Validate hall side
        try std.testing.expect(res.isValid(.hall_side, "back"));
        try std.testing.expect(res.isValid(.hall_side, "front"));
        try std.testing.expect(res.isValid(.hall_side, "forward") == false);
        // Validate filter
        try std.testing.expect(res.isValid(.filter, "1c"));
        try std.testing.expect(res.isValid(.filter, "2a"));
        try std.testing.expect(res.isValid(.filter, "d") == false);
        try std.testing.expect(res.isValid(.filter, "0.1d") == false);
        // Validate control mode
        try std.testing.expect(res.isValid(.control_mode, "speed"));
        try std.testing.expect(res.isValid(.control_mode, "position"));
        try std.testing.expect(res.isValid(.control_mode, "velocity") == false);
        // Validate target
        try std.testing.expect(res.isValid(.target, "1a"));
        try std.testing.expect(res.isValid(.target, "2l"));
        try std.testing.expect(res.isValid(.target, "3.5d"));
        try std.testing.expect(res.isValid(.target, "d") == false);
        try std.testing.expect(res.isValid(.target, "0.1a") == false);
        // Validate log kind
        try std.testing.expect(res.isValid(.log_kind, "axis"));
        try std.testing.expect(res.isValid(.log_kind, "driver"));
        try std.testing.expect(res.isValid(.log_kind, "all"));
        try std.testing.expect(res.isValid(.log_kind, "d") == false);
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
pub var stream: ?std.Io.net.Stream = null;
/// Currently saved endpoint. The endpoint will be overwritten if the client
/// is connected to a different server. Stays null before connected to a socket.
pub var endpoint: ?std.Io.net.IpAddress = null;

pub var allocator: std.mem.Allocator = undefined;

pub var log_allocator: std.mem.Allocator = undefined;
pub const Config = struct {
    host: []u8,
    port: u16,
};
/// Store the configuration.
pub var config: Config = undefined;

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
    parameter = .init(allocator);
    errdefer parameter.deinit();

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
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "speed" },
            },
            .short_description = "Set Carrier speed of specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Set Carrier speed of specified Line. The speed value must be
                \\greater than {d} and less than or equal to {d} {s}.
                \\
                \\Example: Set speed of Line "line1" to 300 {s}.
                \\SET_SPEED line1 300
            , .{
                standard.speed.range.min,
                standard.speed.range.max,
                standard.speed.unit,
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
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "acceleration" },
            },
            .short_description = "Set Carrier acceleration of specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Set Carrier acceleration of specified Line. The acceleration value
                \\must be greater than {d} and less than or equal to {d} {s}.
                \\
                \\Example: Set acceleration of Line "line1" to 200 {s}.
                \\SET_ACCELERATION line1 200
            , .{
                standard.acceleration.range.min,
                standard.acceleration.range.max,
                standard.acceleration.unit,
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
                .{ .name = "Line", .kind = .mmc_client_line },
            },
            .short_description = "Print Carrier speed of the specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier speed of specified Line.
                \\
                \\Example: Print speed of Line "line1".
                \\GET_SPEED line1
            , .{}),
            .execute = &commands.get_speed.impl,
        },
    });
    errdefer command.registry.orderedRemove("GET_SPEED");
    try command.registry.put(.{
        .executable = .{
            .name = "GET_ACCELERATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
            },
            .short_description = "Print Carrier acceleration of the specified Line",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier acceleration of the specified Line.
                \\
                \\Example: Print acceleration of Line "line1".
                \\GET_ACCELERATION line1
            , .{}),
            .execute = &commands.get_acceleration.impl,
        },
    });
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_AXIS_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "filter", .kind = .mmc_client_filter },
            },
            .short_description = "Print Axis information.",
            .long_description = std.fmt.comptimePrint(
                \\Print Axis information of specified Line. Specify which Axis or Axes
                \\to print info via filter. To apply filter, provide ID with filter
                \\suffix (e.g., 1a). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
                \\
                \\Example: Print Axis information of Axis "1" on Line "line1".
                \\PRINT_AXIS_INFO line1 1a
            , .{}),
            .execute = &commands.print_axis_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_AXIS_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_DRIVER_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "filter", .kind = .mmc_client_filter },
            },
            .short_description = "Print Driver information.",
            .long_description = std.fmt.comptimePrint(
                \\Print Driver information of specified Line. Specify which Driver to
                \\print info via filter. To apply filter, provide ID with filter suffix
                \\(e.g., 1d). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
                \\
                \\Example: Get Driver information of Driver "2" on Line "line1".
                \\PRINT_DRIVER_INFO line1 2d
            , .{}),
            .execute = &commands.print_driver_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_DRIVER_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "PRINT_CARRIER_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{
                    .name = "filter",
                    .optional = true,
                    .kind = .mmc_client_filter,
                },
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
                \\
                \\Example: Get Carrier information of Line "line1".
                \\PRINT_CARRIER_INFO line1
                \\
                \\Example: Get Carrier information on Axis "2" on Line "line1".
                \\PRINT_CARRIER_INFO line1 2a
            , .{}),
            .execute = &commands.print_carrier_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("PRINT_CARRIER_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "AXIS_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Axis", .kind = .mmc_client_axis },
                .{
                    .name = "result variable",
                    .optional = true,
                    .resolve = false,
                    .kind = .mmc_client_variable,
                },
            },
            .short_description = "Print Carrier ID on Axis, if exists.",
            .long_description = std.fmt.comptimePrint(
                \\Print Carrier ID on Axis, if exists. Information only provided
                \\when:
                \\ - Carrier is on specified Axis.
                \\ - Carrier is initialized
                \\
                \\Optional: Store Carrier ID in provided variable. Variable cannot start
                \\with a number and is case sensitive.
                \\
                \\Example: Get Carrier ID on Axis "3" on Line "line1".
                \\AXIS_CARRIER line1 3
                \\
                \\Example: Get Carrier ID on Axis "3" on Line "line1" and store
                \\Carrier ID in variable "var".
                \\AXIS_CARRIER line1 3 var
            , .{}),
            .execute = &commands.axis_carrier.impl,
        },
    });
    errdefer _ = command.registry.orderedRemove("AXIS_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_ID",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line(s)", .kind = .mmc_client_line },
                .{
                    .name = "result variable prefix",
                    .optional = true,
                    .resolve = false,
                    .kind = .mmc_client_variable,
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
                \\
                \\Example: Get Carrier IDs on Line "line1".
                \\CARRIER_ID line1
                \\
                \\Example: Get Carrier IDs on Line "line1" and "line2".
                \\CARRIER_ID line1,line2
            , .{}),
            .execute = &commands.carrier_id.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_ID");
    try command.registry.put(.{
        .executable = .{
            .name = "ASSERT_CARRIER_LOCATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{ .name = "location" },
                .{ .name = "threshold", .optional = true },
            },
            .short_description = "Assert Carrier location.",
            .long_description = std.fmt.comptimePrint(
                \\Assert Carrier location. Error if Carrier is not at specified location.
                \\Optional: Provide threshold to change default location threshold value.
                \\Default location threshold value is 1 {s}. Location and threshold must
                \\be provided in {s}.
                \\
                \\Example: Check Carrier location of Carrier "1" on Line "line1" at
                \\location 500 {s}.
                \\ASSERT_CARRIER_LOCATION line1 1 500
                \\
                \\Example: Check Carrier location of Carrier "1" on Line "line1" at
                \\location 500 {s} with threshold 20 {s}.
                \\ASSERT_CARRIER_LOCATION line1 1 500 20
            , .{
                standard.length.unit_short,
                standard.length.unit_long,
                standard.length.unit_short,
                standard.length.unit_short,
                standard.time.unit_long,
            }),
            .execute = &commands.assert_location.impl,
        },
    });
    errdefer command.registry.orderedRemove("ASSERT_CARRIER_LOCATION");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_LOCATION",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{
                    .name = "result variable",
                    .resolve = false,
                    .optional = true,
                    .kind = .mmc_client_variable,
                },
            },
            .short_description = "Display Carrier location, if exists.",
            .long_description = std.fmt.comptimePrint(
                \\Display location of Carrier on specified Line, if exists.
                \\Optional: Store Carrier location in variable. Variable cannot start
                \\with a number and is case sensitive.
                \\
                \\Example: Display Carrier location of Carrier "2" on Line "line1".
                \\CARRIER_LOCATION line1 2
            , .{}),
            .execute = &commands.carrier_location.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_LOCATION");
    try command.registry.put(.{
        .executable = .{
            .name = "CARRIER_AXIS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
            },
            .short_description = "Display Carrier Axis",
            .long_description = std.fmt.comptimePrint(
                \\Display Axis on which Carrier is currently.
                \\
                \\Example: Display Carrier Axis of Carrier "2" on Line "line1".
                \\CARRIER_AXIS line1 2
            , .{}),
            .execute = &commands.carrier_axis.impl,
        },
    });
    errdefer command.registry.orderedRemove("CARRIER_AXIS");
    try command.registry.put(.{
        .executable = .{
            .name = "HALL_STATUS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{
                    .name = "filter",
                    .optional = true,
                    .kind = .mmc_client_filter,
                },
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
                \\
                \\Example: Display all Hall Sensor states on Line "line1".
                \\HALL_STATUS line1
                \\
                \\Example: Display Hall Sensors states on Axis "2" on Line "line1".
                \\HALL_STATUS line1 2a
            , .{}),
            .execute = &commands.hall_status.impl,
        },
    });
    errdefer command.registry.orderedRemove("HALL_STATUS");
    try command.registry.put(.{
        .executable = .{
            .name = "ASSERT_HALL",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Axis", .kind = .mmc_client_axis },
                .{ .name = "side", .kind = .mmc_client_hall_side },
                .{
                    .name = "on/off",
                    .optional = true,
                    .kind = .mmc_client_hall_state,
                },
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
                \\
                \\Example: Assert Hall Sensor "on" state of Axis "3" at side "front" on
                \\Line "line1".
                \\ASSERT_HALL line1 3 front
                \\
                \\Example: Assert Hall Sensor "off" state of Axis "3" at side "front" on
                \\Line "line1".
                \\ASSERT_HALL line1 3 front off
            , .{}),
            .execute = &commands.assert_hall.impl,
        },
    });
    errdefer command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put(.{
        .executable = .{
            .name = "CLEAR_ERRORS",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{
                    .name = "filter",
                    .optional = true,
                    .kind = .mmc_client_filter,
                },
            },
            .short_description = "Clear error states.",
            .long_description = std.fmt.comptimePrint(
                \\Clear error states on all Driver(s) of specified Line.
                \\Optional: Provide filter to specify Driver. To apply filter, provide
                \\ID with filter suffix (e.g., 1d). Supported suffixes are:
                \\ - "a" or "axis" to filter by Axis
                \\ - "c" or "carrier" to filter by Carrier
                \\ - "d" or "driver" to filter by Driver
                \\
                \\Example: Clear error states on all Driver(s) of Line "line1".
                \\CLEAR_ERRORS line1
                \\
                \\Example: Clear error states on Driver "2" of Line "line1".
                \\CLEAR_ERRORS line1 2d
            , .{}),
            .execute = &commands.clear_errors.impl,
        },
    });
    errdefer command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(.{
        .executable = .{
            .name = "DEINITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{
                    .name = "filter",
                    .optional = true,
                    .kind = .mmc_client_filter,
                },
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
                \\
                \\Example: Deinitialize Carrier(s) on Line "line1".
                \\DEINITIALIZE line1
                \\
                \\Example: Deinitialize Carrier(s) on Driver "2" on Line "line1".
                \\DEINITIALIZE line1 2d
                \\
                \\Example: Deinitialize Carrier "3" on Line "line1".
                \\DEINITIALIZE line1 3c
            , .{}),
            .execute = &commands.clear_carrier_info.impl,
        },
    });
    errdefer command.registry.orderedRemove("DEINITIALIZE");
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
                .{ .name = "Line", .kind = .mmc_client_line },
                .{
                    .name = "filter",
                    .optional = true,
                    .kind = .mmc_client_filter,
                },
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
                \\
                \\Example: Release Carrier(s) on Line "line1".
                \\RELEASE_CARRIER line1
                \\
                \\Example: Release Carrier(s) on Driver "2" on Line "line1".
                \\RELEASE_CARRIER line1 2d
                \\
                \\Example: Release Carrier "3" on Line "line1".
                \\RELEASE_CARRIER line1 3c
            , .{}),
            .execute = &commands.release_carrier.impl,
        },
    });
    errdefer command.registry.orderedRemove("RELEASE_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "AUTO_INITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{
                    .name = "Line(s)",
                    .optional = true,
                    .kind = .mmc_client_line,
                },
            },
            .short_description = "Initialize all Carriers automatically.",
            .long_description = std.fmt.comptimePrint(
                \\Automatically initializes all uninitialized Carriers. This process
                \\operates on carrier clusters, where a cluster is defined as a group of
                \\uninitialized Carriers located on adjacent Axis. Each cluster requires
                \\at least one free Axis to successfully initialize cluster. Multiple
                \\Line auto initialization is supported (e.g., line1,line2,line3). If
                \\Line is not provided, auto initializes Carriers on all Lines.
                \\
                \\Example: Auto initialize Carrier(s) on all Lines.
                \\AUTO_INITIALIZE
                \\
                \\Example: Auto initialize Carrier(s) on Line "line1".
                \\AUTO_INITIALIZE line1
                \\
                \\Example: Auto initialize Carrier(s) on Line "line1" and "line2".
                \\AUTO_INITIALIZE line1,line2
            , .{}),
            .execute = &commands.auto_initialize.impl,
        },
    });
    errdefer command.registry.orderedRemove("AUTO_INITIALIZE");
    try command.registry.put(.{
        .executable = .{
            .name = "CALIBRATE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
            },
            .short_description = "Calibrate Track Line.",
            .long_description = std.fmt.comptimePrint(
                \\Calibrate Track Line. Uninitialized Carrier must be positioned at start
                \\of Line and first Axis Hall Sensors are both in "on" state.
                \\
                \\Example: Calibrate Line "line1".
                \\CALIBRATE line1
            , .{}),
            .execute = &commands.calibrate.impl,
        },
    });
    errdefer command.registry.orderedRemove("CALIBRATE");
    try command.registry.put(.{
        .executable = .{
            .name = "SET_ZERO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
            },
            .short_description = "Set Line zero position.",
            .long_description = std.fmt.comptimePrint(
                \\Set zero position for specified Line. Initialized Carrier must be on
                \\first Axis of specified Line.
                \\
                \\Example: Set zero position for Line "line1".
                \\SET_ZERO line1
            , .{}),
            .execute = &commands.set_line_zero.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_ZERO");
    try command.registry.put(.{
        .executable = .{
            .name = "INITIALIZE",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Axis", .kind = .mmc_client_axis },
                .{ .name = "direction", .kind = .mmc_client_direction },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{
                    .name = "link Axis",
                    .resolve = false,
                    .optional = true,
                    .kind = .mmc_client_link_axis,
                },
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
                \\
                \\Example: Initialize Carrier on Axis "3" on Line "line1". Assign Carrier
                \\ID "123". Initializing movement direction toward Axis "4".
                \\INITIALIZE line1 3 forward 123
                \\
                \\Example: Initialize Carrier on Axis "3" and "4" on Line "line1". Assign
                \\Carrier ID "123". Initializing movement direction toward Axis "3".
                \\INITIALIZE line1 3 backward 123 next
            , .{}),
            .execute = &commands.isolate.impl,
        },
    });
    errdefer command.registry.orderedRemove("INITIALIZE");
    try command.registry.put(.{ .executable = .{
        .name = "WAIT_INITIALIZE",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "Carrier", .kind = .mmc_client_carrier },
            .{ .name = "timeout", .optional = true },
        },
        .short_description = "Wait until Carrier initialization complete.",
        .long_description = std.fmt.comptimePrint(
            \\Pauses command execution until specified Carrier completes initialization.
            \\Optional: Provide timeout. Returns error if specified timeout is exceeded.
            \\Timeout must be provided in {s}.
            \\
            \\Example: Wait for initialization of Carrier "3" on Line "line1".
            \\WAIT_INITIALIZE line1 3
            \\
            \\Example: Wait max 5000 {s} for initialization of Carrier "3" on
            \\Line "line1".
            \\WAIT_INITIALIZE line1 3 5000
        , .{
            standard.time.unit_long,
            standard.time.unit_short,
        }),
        .execute = &commands.wait.isolate,
    } });
    errdefer command.registry.orderedRemove("WAIT_INITIALIZE");
    try command.registry.put(.{
        .executable = .{
            .name = "WAIT_MOVE_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{ .name = "timeout", .optional = true },
            },
            .short_description = "Wait until Carrier movement complete.",
            .long_description = std.fmt.comptimePrint(
                \\Pauses command execution until specified Carrier completes movement.
                \\Optional: Provide timeout. Returns error if specified timeout is
                \\exceeded. Timeout must be provided in {s}.
                \\
                \\Example: Wait for movement completion of Carrier "3" on Line "line1".
                \\WAIT_MOVE_CARRIER line1 3
                \\
                \\Example: Wait max 5000 {s} movement completion of Carrier "3" on Line
                \\"line1".
                \\WAIT_MOVE_CARRIER line1 3 5000
            , .{
                standard.time.unit_long,
                standard.time.unit_short,
            }),
            .execute = &commands.wait.moveCarrier,
        },
    });
    errdefer command.registry.orderedRemove("WAIT_MOVE_CARRIER");
    try command.registry.put(.{
        .executable = .{
            .name = "MOVE_CARRIER",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{ .name = "target", .kind = .mmc_client_target },
                .{ .name = "CAS", .optional = true, .kind = .mmc_client_cas },
                .{
                    .name = "control mode",
                    .optional = true,
                    .kind = .mmc_client_control_mode,
                },
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
                \\Optional: Provide "on" or "off" to specify CAS (Collision Avoidance
                \\System) activation (enabled by default).
                \\Optional: Provide following to specify movement control mode:
                \\- "speed" to move Carrier with speed profile feedback.
                \\- "position" to move Carrier with position profile feedback.
                \\
                \\Example: Move Carrier "2" to Axis "3" on Line "line1".
                \\MOVE_CARRIER line1 2 3a
                \\
                \\Example: Move Carrier "2" to location 150 {s} on Line "line1" and disable
                \\CAS.
                \\MOVE_CARRIER line1 2 150l off
                \\
                \\Example: Move Carrier "2" to location 150 {s} on Line "line1" and move
                \\Carrier with speed profile feedback.
                \\MOVE_CARRIER line1 2 150l on speed
            , .{
                standard.length.unit_short,
                standard.length.unit_short,
                standard.length.unit_short,
                standard.length.unit_short,
            }),
            .execute = &commands.move.impl,
        },
    });
    errdefer command.registry.orderedRemove("MOVE_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "PUSH_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "Axis", .kind = .mmc_client_axis },
            .{ .name = "direction", .kind = .mmc_client_direction },
            .{
                .name = "Carrier",
                .optional = true,
                .kind = .mmc_client_carrier,
            },
        },
        .short_description = "Push Carrier on the specified Axis.",
        .long_description = std.fmt.comptimePrint(
            \\Push a Carrier on the specified Axis. This movement targets a
            \\distance of Carrier length, and thus if it is used to cross a Line
            \\boundary, the receiving Axis at the destination Line must be in
            \\pulling state. Direction must be provided as:
            \\- forward  (direction of increasing Axis number)
            \\- backward (direction of decreasing Axis number)
            \\
            \\Optional: Provide Carrier to move the specified Carrier to the center
            \\of the specified Axis, then push it according to direction.
            \\
            \\Example: Push Carrier on Axis "3" to Axis "4". If Line "line1" only has
            \\3 Axes, push Carrier out from Line "line1" to Line "line2".
            \\PUSH_CARRIER line1 3 forward
            \\
            \\Example: Move Carrier "2" to Axis "3" and transition to push movement to
            \\Axis "4". If Line "line1" only has 3 Axes, then transition to push movement
            \\out from Line "line1" to Line "line2".
            \\PUSH_CARRIER line1 3 forward 2
        , .{}),
        .execute = &commands.push.impl,
    } });
    errdefer command.registry.orderedRemove("PUSH_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "PULL_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "Axis", .kind = .mmc_client_axis },
            .{ .name = "Carrier", .kind = .mmc_client_carrier },
            .{ .name = "direction", .kind = .mmc_client_direction },
            .{ .name = "location", .optional = true },
            .{ .name = "CAS", .optional = true, .kind = .mmc_client_cas },
        },
        .short_description = "Pull incoming Carrier.",
        .long_description = std.fmt.comptimePrint(
            \\Sets the specified Axis to a pulling state, enabling Axis to initialize
            \\and move incoming carrier to specified Axis. The pulled Carrier is
            \\assigned with the specified Carrier ID. There must be no Carrier on
            \\pulling Axis upon invocation. Direction must be provided as:
            \\ - forward  (direction of increasing Axis number)
            \\ - backward (direction of decreasing Axis number)
            \\
            \\Optional: Provide location to move Carrier after completed pulling
            \\Carrier. Location must be provided as:
            \\- {s} (move Carrier to specified location after pulled to
            \\  specified  Axis), or
            \\- "nan" (Carrier can move through external force after pulled to
            \\  specified Axis).
            \\
            \\Optional: Provide "on" or "off" to specify CAS (Collision
            \\Avoidance System) activation (enabled by default) while Carrier is
            \\being moved to specified location.
            \\
            \\Example: Pull Carrier onto Axis "1" on Line "line2" from Line "line1" and
            \\assign Carrier ID to "123".
            \\PULL_CARRIER line2 1 123 forward
            \\
            \\Example: Pull Carrier to Line "line2" from Line "line1", assign Carrier ID
            \\to "123" and move Carrier "123" to location 1500 {s} upon recognized on
            \\Line "line2".
            \\PULL_CARRIER line2 1 123 forward 1500
            \\
            \\Example: Pull Carrier to Line "line2" from Line "line1", assign Carrier ID
            \\to "123", and move Carrier "123" to location 1500 {s} with CAS deactivated
            \\upon recognized on Line "line2".
            \\PULL_CARRIER line2 1 123 forward 1500 off
        , .{
            standard.length.unit_long,
            standard.length.unit_short,
            standard.length.unit_short,
        }),
        .execute = &commands.pull.impl,
    } });
    errdefer command.registry.orderedRemove("PULL_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "STOP_PULL_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "filter", .optional = true, .kind = .mmc_client_filter },
        },
        .short_description = "Stop pulling Carrier at axis.",
        .long_description = std.fmt.comptimePrint(
            \\Stop active Carrier pull of specified Line.
            \\Optional: Provide filter to specify selection of pull. To apply filter,
            \\provide ID with filter suffix (e.g., 1c). Supported suffixes are:
            \\ - "a" or "axis" to filter by Axis
            \\ - "c" or "Carrier" to filter by Carrier
            \\ - "d" or "driver" to filter by Driver
            \\
            \\Example: Stop pull Carrier(s) on Line "line1".
            \\STOP_PULL_CARRIER line1
            \\
            \\Example: Stop pull for Axis "1" on Line "line1".
            \\STOP_PULL_CARRIER line1 1a
        , .{}),
        .execute = &commands.stop_pull.impl,
    } });
    errdefer command.registry.orderedRemove("STOP_PULL_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "STOP_PUSH_CARRIER",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "filter", .optional = true, .kind = .mmc_client_filter },
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
            \\
            \\Example: Stop push Carrier(s) on Line "line1".
            \\STOP_PUSH_CARRIER line1
            \\
            \\Example: Stop push for Axis "3" on Line "line1".
            \\STOP_PUSH_CARRIER line1 3a
        , .{}),
        .execute = &commands.stop_push.impl,
    } });
    errdefer command.registry.orderedRemove("STOP_PUSH_CARRIER");
    try command.registry.put(.{ .executable = .{
        .name = "WAIT_AXIS_EMPTY",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "Axis", .kind = .mmc_client_axis },
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
            \\
            \\Example: Wait until no Carrier on Axis "2" on Line "line1".
            \\WAIT_AXIS_EMPTY line1 2
            \\
            \\Example: Wait max 5000 {s} until no Carrier on Axis "2" on Line "line1".
            \\WAIT_AXIS_EMPTY line1 2 5000
        , .{
            standard.time.unit_long,
            standard.time.unit_short,
        }),
        .execute = &commands.wait.axisEmpty,
    } });
    errdefer command.registry.orderedRemove("WAIT_AXIS_EMPTY");
    try command.registry.put(.{
        .executable = .{
            .name = "ADD_LOG_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "kind", .kind = .mmc_client_log_kind },
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
                \\
                \\Example: Add Driver(s) on Line "line1" to logging configuration.
                \\ADD_LOG_INFO line1 driver
                \\
                \\Example: Add Axis "2" to "3" on Line "line1" to logging configuration.
                \\ADD_LOG_INFO line1 axis 2:3
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
            \\
            \\Example: Start logging process and provide logging data for a duration of
            \\10 s before logging is stopped.
            \\START_LOG_INFO 10
            \\
            \\Example: Start logging process and save logging file at
            \\"folder/log_info.csv".
            \\START_LOG_INFO 10 folder/log_info.csv
        , .{}),
        .execute = &commands.log.start,
    } });
    errdefer command.registry.orderedRemove("START_LOG_INFO");
    try command.registry.put(.{
        .executable = .{
            .name = "REMOVE_LOG_INFO",
            .parameters = &[_]command.Command.Executable.Parameter{
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "kind", .kind = .mmc_client_log_kind },
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
                \\
                \\Example: Clear logging configuration for Line "line1".
                \\REMOVE_LOG_INFO line1 all
                \\
                \\Example: Remove Driver(s) on Line "line1" from logging configuration.
                \\REMOVE_LOG_INFO line1 driver
                \\
                \\Example: Remove Axis "1" to "3" on Line "line1" from logging configuration.
                \\REMOVE_LOG_INFO line1 axis 1:3
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
            .{ .name = "Line", .kind = .mmc_client_line },
            .{ .name = "filter", .optional = true, .kind = .mmc_client_filter },
        },
        .short_description = "Print Axis and Driver errors.",
        .long_description = std.fmt.comptimePrint(
            \\Print Axis and Driver errors on specified Line.
            \\Optional: Provide filter to specify selection of error(s). To apply filter,
            \\provide ID with filter suffix (e.g., 1a). Supported suffixes are:
            \\ - "a" or "axis" to filter by Axis
            \\ - "c" or "Carrier" to filter by Carrier
            \\ - "d" or "driver" to filter by Driver
            \\
            \\Example: Print Axis and Driver errors on Line "line1".
            \\PRINT_ERRORS line1
            \\
            \\Example: Print errors on Axis "3" on Line "line1".
            \\PRINT_ERRORS line1 3a
        , .{}),
        .execute = &commands.show_errors.impl,
    } });
    errdefer command.registry.orderedRemove("PRINT_ERRORS");
    try command.registry.put(.{ .executable = .{
        .name = "STOP",
        .parameters = &[_]command.Command.Executable.Parameter{
            .{ .name = "Line", .kind = .mmc_client_line },
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
                .{ .name = "Line", .kind = .mmc_client_line },
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
                .{ .name = "Line", .kind = .mmc_client_line },
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
                .{ .name = "Line", .kind = .mmc_client_line },
                .{ .name = "Carrier", .kind = .mmc_client_carrier },
                .{ .name = "new Carrier id", .kind = .mmc_client_carrier },
            },
            .short_description = "Modify Carrier ID.",
            .long_description = std.fmt.comptimePrint(
                \\Modify Carrier ID of initialized Carrier. Carrier ID must be unique per
                \\Line.
                \\
                \\Example: Modify Carrier ID of Carrier "3" to "4" on Line "line1".
                \\SET_CARRIER_ID line1 3 4
            , .{}),
            .execute = &commands.set_carrier_id.impl,
        },
    });
    errdefer command.registry.orderedRemove("SET_CARRIER_ID");
}

pub fn deinit() void {
    // TODO: Find a better way for passing io to disconnect
    var single_threaded: std.Io.Threaded = .init_single_threaded;
    commands.disconnect.impl(single_threaded.io(), &.{}) catch {};
    parameter.deinit();
    allocator.free(config.host);
    if (debug_allocator.detectLeaks() != 0) {
        std.log.debug("Leaks detected", .{});
    }
}

pub fn matchLine(name: []const u8) !usize {
    for (lines) |line| {
        if (std.mem.eql(u8, line.name, name)) return line.index;
    } else return error.LineNameNotFound;
}

/// Track a command until it executed completely followed by removing that
/// command from the server.
pub fn waitCommandCompleted(io: std.Io) !void {
    const net = stream orelse return error.ServerNotConnected;
    const command_id = b: {
        var response = try readResponse(io, allocator, net);
        defer response.deinit(allocator);
        break :b switch (response.body orelse return error.InvalidResponse) {
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
    defer removeCommand(io, command_id) catch {};
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
        try sendRequest(io, allocator, net, request);
        var response = try readResponse(io, allocator, net);
        defer response.deinit(allocator);
        var commands_resp = switch (response.body orelse
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

fn removeCommand(io: std.Io, id: u32) !void {
    const net = stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .remove_command = .{ .command = id },
                },
            },
        },
    };
    // Send message
    try request.encode(&net_writer.interface, allocator);
    try net_writer.interface.flush();
    // Receive message
    while (true) {
        try command.checkCommandInterrupt();
        const byte = net_reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return net_reader.err orelse error.Unexpected;
                },
            }
        };
        if (byte > 0) break;
    }
    var proto_reader: std.Io.Reader = .fixed(net_reader.interface.buffered());
    var response: api.protobuf.mmc.Response = try .decode(
        &proto_reader,
        allocator,
    );
    const removed_id = switch (response.body orelse
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

pub fn sendRequest(
    io: std.Io,
    gpa: std.mem.Allocator,
    net: std.Io.net.Stream,
    request: api.protobuf.mmc.Request,
) !void {
    var writer_buf: [4096]u8 = undefined;
    var net_writer = net.writer(io, &writer_buf);
    try request.encode(&net_writer.interface, gpa);
    try net_writer.interface.flush();
}

pub fn readResponse(
    io: std.Io,
    gpa: std.mem.Allocator,
    net: std.Io.net.Stream,
) !api.protobuf.mmc.Response {
    var reader_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    while (true) {
        // Read until the length is equal for consecutive peek.
        try command.checkCommandInterrupt();
        const prev_buffered_len = net_reader.interface.bufferedLen();
        if (net_reader.interface.peekByte()) |_| {
            if (prev_buffered_len == 0) continue;
            if (net_reader.interface.bufferedLen() == prev_buffered_len)
                break;
        } else |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => {
                    std.log.err("{t}", .{e});
                    continue;
                },
                std.Io.Reader.Error.ReadFailed => {
                    return switch (net_reader.err orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        }
    }
    var proto_reader: std.Io.Reader =
        .fixed(try net_reader.interface.take(
            net_reader.interface.bufferedLen(),
        ));
    return try .decode(&proto_reader, gpa);
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
