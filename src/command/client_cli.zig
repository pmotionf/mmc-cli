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

const Client = @This();

const Line = struct {
    index: Line.Index,
    id: Line.Id,
    axes: []Axis,
    drivers: []Driver,
    name: []u8,
    velocity: u6,
    acceleration: u8,
    length: struct {
        axis: u32,
        carrier: u32,
    },

    /// Maximum number of axis
    pub const max = 64 * 4;
    pub const Index = Driver.Index;
    pub const Id = Driver.Id;
};

const Axis = struct {
    driver: *const Driver,
    index: Index,
    id: Id,

    /// Maximum number of axis
    pub const max = 64 * 4 * 3;

    pub const Index = struct {
        line: Axis.Index.Line,
        driver: Axis.Index.Driver,

        pub const Line = std.math.IntFittingRange(0, Axis.max - 1);
        pub const Driver = std.math.IntFittingRange(0, 2);
    };

    pub const Id = struct {
        line: Axis.Id.Line,
        driver: Axis.Id.Driver,

        pub const Line = std.math.IntFittingRange(1, Axis.max);
        pub const Driver = std.math.IntFittingRange(1, 3);
    };
};

const Driver = struct {
    line: *const Line,
    index: Driver.Index,
    id: Driver.Id,
    axes: []Axis,

    /// Maximum number of driver
    pub const max = 64 * 4;

    pub const Index = std.math.IntFittingRange(0, Driver.max - 1);
    pub const Id = std.math.IntFittingRange(1, Driver.max);
};

const Log = struct {
    lines: []Log.Config = &.{},
    duration: f64 = 0,
    path: []const u8 = &.{},
    data: CircularBufferAlloc(Data) = .{},

    pub const Kind = enum { axis, driver };
    /// Logging configuration for each line. Only the latest configuration
    /// will be used for logging process.
    pub const Config = struct {
        /// Line ID to be logged
        id: Line.Id = 0,
        /// Flag for logging axis info for the line.
        axis: bool = false,
        /// Flag for logging driver info for the line.
        driver: bool = false,
        /// Axis range to be logged of the line.
        axis_id_range: struct {
            start: Axis.Id.Line = 0,
            end: Axis.Id.Line = 0,
        } = .{},
    };

    pub const Data = struct {
        timestamp: f64 = 0,
        axes: [Client.Axis.max]Data.Axis =
            [_]Data.Axis{std.mem.zeroInit(Data.Axis, .{})} ** Client.Axis.max,
        drivers: [Client.Driver.max]Data.Driver =
            [_]Data.Driver{std.mem.zeroInit(Data.Driver, .{})} ** Client.Driver.max,

        pub const Axis = struct {
            hall: struct { back: bool, front: bool },
            motor_enabled: bool,
            pulling: bool,
            pushing: bool,
            carrier: Data.Axis.Carrier,
            errors: struct { overcurrent: bool },

            pub const Carrier = struct {
                id: Client.Axis.Id.Line,
                position: f32,
                state: InfoResponse.System.Carrier.Info.State,
                cas: struct { enabled: bool, triggered: bool },
            };
        };

        pub const Driver = struct {
            connected: bool,
            available: bool,
            servo_enabled: bool,
            stopped: bool,
            paused: bool,
            errors: struct {
                control_loop_max_time_exceeded: bool,
                power: struct { overvoltage: bool, undervoltage: bool },
                inverter_overheat: bool,
                comm: struct { from_prev: bool, from_next: bool },
            },
        };

        /// Parse raw axis info and error into this type. Write the data to
        /// the context and return the next data index. Data are guaranteed
        /// to not have a null field for any optional.
        pub fn parseAxis(
            self: *Log.Data,
            infos: []InfoResponse.System.Axis.Info,
            errors: []InfoResponse.System.Axis.Error,
            carriers: []InfoResponse.System.Carrier.Info,
            start_idx: usize,
        ) usize {
            var index = start_idx;
            for (infos, errors) |info, err| {
                self.axes[index] = .{
                    .motor_enabled = info.motor_enabled,
                    .pulling = info.waiting_pull,
                    .pushing = info.waiting_push,
                    .carrier = std.mem.zeroInit(Data.Axis.Carrier, .{}),
                    .errors = .{
                        .overcurrent = err.overcurrent,
                    },
                    .hall = .{
                        .back = info.hall_alarm.?.back,
                        .front = info.hall_alarm.?.front,
                    },
                };
                index += 1;
            }
            for (carriers) |carrier| {
                const axis = carrier.axis.?;
                const ti = @typeInfo(@TypeOf(axis)).@"struct";
                inline for (ti.fields) |field| {
                    const axis_idx = if (@typeInfo(field.type) == .optional) b: {
                        if (@field(axis, field.name)) |id| {
                            break :b id - 1;
                        } else break;
                    } else @field(axis, field.name) - 1;
                    self.axes[start_idx + axis_idx].carrier = .{
                        .id = @intCast(carrier.id),
                        .position = carrier.position,
                        .state = carrier.state,
                        .cas = .{
                            .enabled = carrier.cas.?.enabled,
                            .triggered = carrier.cas.?.triggered,
                        },
                    };
                }
            }
            return index;
        }
        /// Parse raw driver info and error into this type. Write the data to
        /// the context and return the next data index. Data are guaranteed
        /// to not have a null field for any optional.
        pub fn parseDriver(
            self: *Log.Data,
            infos: []InfoResponse.System.Driver.Info,
            errors: []InfoResponse.System.Driver.Error,
            start_idx: usize,
        ) usize {
            var index = start_idx;
            for (infos, errors) |info, err| {
                self.drivers[index] = .{
                    .connected = info.connected,
                    .available = info.available,
                    .servo_enabled = info.servo_enabled,
                    .stopped = info.stopped,
                    .paused = info.paused,
                    .errors = .{
                        .control_loop_max_time_exceeded = err.control_loop_time_exceeded,
                        .inverter_overheat = err.inverter_overheat,
                        .comm = .{
                            .from_prev = err.communication_error.?.from_prev,
                            .from_next = err.communication_error.?.from_next,
                        },
                        .power = .{
                            .overvoltage = err.power_error.?.overvoltage,
                            .undervoltage = err.power_error.?.undervoltage,
                        },
                    },
                };
                index += 1;
            }
            return index;
        }
    };

    /// Initialize the memory for storing logging flag. Initialized by client_cli
    /// arena allocator.
    pub fn init(
        line: std.math.IntFittingRange(0, Line.max - 1),
    ) !Log {
        return Log{
            .lines = try allocator.alloc(Log.Config, line),
            .data = .{},
        };
    }

    fn deinit(self: *Log) void {
        allocator.free(self.lines);
    }

    /// Request info and write the data to the log
    fn get(
        self: *Log,
        timestamp: f64,
        sock: ?network.Socket,
    ) !void {
        var data: Log.Data = .{};
        var axis_idx: usize = 0;
        var driver_idx: usize = 0;
        var info_msg: InfoRequest = InfoRequest.init(log_allocator);
        data.timestamp = timestamp;
        for (self.lines) |line| {
            defer log_fba.reset();
            if (!line.axis and !line.driver) continue;
            const start_axis = lines[line.id - 1].axes[line.axis_id_range.start - 1];
            const end_axis = lines[line.id - 1].axes[line.axis_id_range.end - 1];
            info_msg.body = .{
                .system = .{
                    .line_id = @intCast(line.id),
                    .driver = true,
                    .axis = true,
                    .carrier = true,
                    .source = .{
                        .driver_range = .{
                            .start_id = @intCast(start_axis.driver.id),
                            .end_id = @intCast(end_axis.driver.id),
                        },
                    },
                },
            };
            const system = try sendRequest(
                info_msg,
                log_allocator,
                InfoResponse.System,
                sock,
            );
            var axis_infos: []InfoResponse.System.Axis.Info = &.{};
            var axis_errors: []InfoResponse.System.Axis.Error = &.{};
            var driver_infos: []InfoResponse.System.Driver.Info = &.{};
            var driver_errors: []InfoResponse.System.Driver.Error = &.{};
            var carrier_infos: []InfoResponse.System.Carrier.Info = &.{};
            // Validate response
            if (system.line_id != line.id) return error.InvalidResponse;
            if (line.axis) {
                axis_infos = system.axis_infos.items;
                axis_errors = system.axis_errors.items;
                carrier_infos = system.carrier_infos.items;
                const axes = line.axis_id_range.end - line.axis_id_range.start + 1;
                if (axis_infos.len != axis_errors.len or axis_infos.len != axes)
                    return error.InvalidResponse;
                for (axis_infos, axis_errors) |info, err| {
                    try validateResponse(info);
                    try validateResponse(err);
                }
                for (carrier_infos) |carrier| try validateResponse(carrier);
            }
            if (line.driver) {
                driver_infos = system.driver_infos.items;
                driver_errors = system.driver_errors.items;
                const start_driver =
                    lines[line.id - 1].axes[line.axis_id_range.start - 1].driver;
                const end_driver =
                    lines[line.id - 1].axes[line.axis_id_range.end - 1].driver;
                const drivers = end_driver.id - start_driver.id + 1;
                if (driver_infos.len != driver_errors.len or
                    driver_infos.len != drivers) return error.InvalidResponse;
                for (driver_infos, driver_errors) |info, err| {
                    try validateResponse(info);
                    try validateResponse(err);
                }
            }
            // Parse the response
            if (line.axis)
                axis_idx = data.parseAxis(
                    axis_infos,
                    axis_errors,
                    carrier_infos,
                    axis_idx,
                );

            if (line.driver)
                driver_idx = data.parseDriver(
                    driver_infos,
                    driver_errors,
                    driver_idx,
                );
        }
        self.data.writeItemOverwrite(data);
    }

    fn writeHeaders(
        writer: *std.Io.Writer,
        prefix: []const u8,
        comptime parent: []const u8,
        comptime Parent: type,
    ) !void {
        const ti = @typeInfo(Parent).@"struct";
        inline for (ti.fields) |field| {
            if (@typeInfo(field.type) == .@"struct") {
                if (parent.len == 0)
                    try writeHeaders(
                        writer,
                        prefix,
                        field.name,
                        field.type,
                    )
                else
                    try writeHeaders(
                        writer,
                        prefix,
                        parent ++ "." ++ field.name,
                        field.type,
                    );
            } else {
                if (parent.len == 0)
                    try writer.print(
                        "{s}_{s},",
                        .{ prefix, field.name },
                    )
                else
                    try writer.print(
                        "{s}_{s},",
                        .{ prefix, parent ++ "." ++ field.name },
                    );
            }
        }
    }

    fn writeValues(writer: *std.Io.Writer, parent: anytype) !void {
        const parent_ti = @typeInfo(@TypeOf(parent)).@"struct";
        inline for (parent_ti.fields) |field| {
            if (@typeInfo(field.type) == .@"struct")
                try writeValues(writer, @field(parent, field.name))
            else {
                if (@typeInfo(field.type) == .optional) {
                    if (@field(parent, field.name)) |value|
                        try writer.print("{},", .{value})
                    else
                        try writer.write("None,");
                } else if (@typeInfo(field.type) == .@"enum") {
                    try writer.print(
                        "{d},",
                        .{@intFromEnum(@field(parent, field.name))},
                    );
                } else try writer.print(
                    "{},",
                    .{@field(parent, field.name)},
                );
            }
        }
    }

    fn write(writer: *std.Io.Writer) !void {
        // Write header for the logging file
        try writer.writeAll("timestamp,");
        var num_of_drivers: usize = 0;
        var num_of_axis: usize = 0;
        for (log.lines) |line| {
            var buf: [64]u8 = undefined;
            if (!line.axis and !line.driver) continue;
            const start_axis = lines[line.id - 1].axes[line.axis_id_range.start - 1];
            const end_axis = lines[line.id - 1].axes[line.axis_id_range.end - 1];
            if (line.driver) {
                for (start_axis.driver.id..end_axis.driver.id + 1) |id| {
                    num_of_drivers += 1;
                    try writeHeaders(
                        writer,
                        try std.fmt.bufPrint(
                            &buf,
                            "{s}_driver{d}",
                            .{ lines[line.id - 1].name, id },
                        ),
                        "",
                        Log.Data.Driver,
                    );
                }
            }
            if (line.axis) {
                for (start_axis.id.line..end_axis.id.line + 1) |id| {
                    num_of_axis += 1;
                    try writeHeaders(
                        writer,
                        try std.fmt.bufPrint(
                            &buf,
                            "{s}_axis{d}",
                            .{ lines[line.id - 1].name, id },
                        ),
                        "",
                        Log.Data.Axis,
                    );
                }
            }
        }
        // Write the data to the logging file
        while (log.data.readItem()) |item| {
            try writer.writeByte('\n');
            try writer.print("{d},", .{item.timestamp});
            for (0..num_of_drivers) |i| {
                try writeValues(writer, item.drivers[i]);
            }
            for (0..num_of_axis) |i| {
                try writeValues(writer, item.axes[i]);
            }
        }
    }

    /// Handler for start the logging process
    fn start() !void {
        defer {
            log.duration = 0;
            allocator.free(log.path);
        }
        // Assumption: The register from mcl is updated every 3 ms;
        const mcl_update = 3;
        const logging_size_float =
            log.duration * @as(f64, @floatFromInt(std.time.ms_per_s)) / mcl_update;
        if (std.math.isNan(logging_size_float) or
            std.math.isInf(logging_size_float) or
            !std.math.isFinite(logging_size_float)) return error.InvalidDuration;
        var initialized = false;
        for (log.lines) |line| {
            if (line.axis or line.driver) {
                initialized = true;
                break;
            }
        }
        if (!initialized) return error.NoConfiguredLogging;
        std.log.info("The registers will be logged to {s}", .{log.path});
        const log_file = try std.fs.cwd().createFile(log.path, .{});
        defer log_file.close();
        const logging_size = @as(usize, @intFromFloat(logging_size_float));
        log.data = try CircularBufferAlloc(Log.Data).initCapacity(allocator, logging_size);
        defer log.data.deinit();
        const log_time_start = std.time.microTimestamp();
        var timer = try std.time.Timer.start();
        const endpoint = if (main_socket) |main|
            try main.getRemoteEndPoint()
        else
            return error.ServerNotConnected;
        var addr_buf: [15]u8 = undefined;
        const ipv4 = endpoint.address.ipv4.value;
        const addr = try std.fmt.bufPrint(
            &addr_buf,
            "{d}.{d}.{d}.{d}",
            .{ ipv4[0], ipv4[1], ipv4[2], ipv4[3] },
        );
        const socket: ?network.Socket = try network.connectToHost(
            allocator,
            addr,
            endpoint.port,
            .tcp,
        );
        defer if (socket) |s| s.close();
        // TODO: This approach make checkError cannot be used by other thread.
        //       Find a better approach.
        // Remove any previous detected error.
        command.checkError() catch {};
        defer std.log.debug("Logging stopped", .{});
        while (true) {
            // Check if there is an error after the log started, including the
            // command cancellation.
            command.checkError() catch |e| {
                std.log.debug("{t}", .{e});
                std.log.debug("{?f}", .{@errorReturnTrace()});
                break;
            };
            while (timer.read() < mcl_update * std.time.ns_per_ms) {}
            const timestamp = std.time.microTimestamp() - log_time_start;
            timer.reset();
            log.get(
                @floatFromInt(@divFloor(timestamp, std.time.ms_per_s)),
                socket,
            ) catch |e| {
                std.log.debug("{t}", .{e});
                std.log.debug("{?f}", .{@errorReturnTrace()});
                // NOTE: Should the main thread be notified to stop any running
                //       command? Example use case: When execute a file, if the
                //       logging failed, it is hard to notice that the logging
                //       is finished while keep executing commands.
                break;
            };
        }
        // var write_buf: [4096]u8 = undefined;
        var log_writer = log_file.writer(&.{});
        try write(&log_writer.interface);
        try log_writer.interface.flush();
        std.log.info("Logging data is saved successfully.", .{});
    }
};

var log: Log = .{};
var lines: []Line = &.{};

// TODO: Decide the value properly
var fba_buffer: [1_024_000]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
const fba_allocator = fba.allocator();

// TODO: Calculate the memory required for logging
var log_buffer: [1_024_000]u8 = undefined;
var log_fba = std.heap.FixedBufferAllocator.init(&log_buffer);
const log_allocator = log_fba.allocator();

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var IP_address: []u8 = &.{};
var port: u16 = 0;

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
            .{ .name = "endpoint", .optional = true },
        },
        .short_description = "Connect program to the server.",
        .long_description =
        \\Attempt to connect the client application to the server. The IP address
        \\and the port should be provided in the configuration file. The port
        \\and IP address can be overwritten by providing the new port and IP
        \\address by specifying the endpoint as "IP_ADDRESS:PORT".
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
        \\to 6.0 meters-per-second.
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
        \\less than or equal to 24.5 meters-per-second-squared.
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
        \\by name. Speed is in meters-per-second.
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
        \\referenced by name. Acceleration is in meters-per-second-squared.
        ,
        .execute = &clientGetAcceleration,
    });
    errdefer command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(.{
        .name = "PRINT_AXIS_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Print the axis information.",
        .long_description =
        \\Print the information tied to an axis.
        ,
        .execute = &clientAxisInfo,
    });
    errdefer command.registry.orderedRemove("PRINT_AXIS_INFO");
    try command.registry.put(.{
        .name = "PRINT_DRIVER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "driver" },
        },
        .short_description = "Print the driver information.",
        .long_description =
        \\Print the information tied to a driver.
        ,
        .execute = &clientDriverInfo,
    });
    errdefer command.registry.orderedRemove("PRINT_DRIVER_INFO");
    try command.registry.put(.{
        .name = "PRINT_CARRIER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "carrier" },
        },
        .short_description = "Print the carrier information.",
        .long_description =
        \\Print the information tied to a carrier.
        ,
        .execute = &clientCarrierInfo,
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
        .name = "RESET_SYSTEM",
        .short_description = "Reset the system state.",
        .long_description =
        \\Clear any carrier and errors occurred across the system. In addition,
        \\reset any push and pull state on every axis.
        ,
        .execute = &clientResetSystem,
    });
    errdefer command.registry.orderedRemove("CLEAR_CARRIER_INFO");
    try command.registry.put(.{
        .name = "RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis", .optional = true },
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
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target axis center.",
        .long_description =
        \\Move given carrier to the center of target axis. The carrier ID must be
        \\currently recognized within the motion system. Provide "true" to disable
        \\CAS (collision avoidance system) for the command.
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
            .{ .name = "disable cas", .optional = true },
        },
        .short_description = "Move carrier to target location.",
        .long_description =
        \\Move given carrier to target location. The carrier ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. Provide "true" to
        \\disable CAS (collision avoidance system) for the command.
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
        .execute = &clientCarrierPosMoveDistance,
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
        .execute = &clientCarrierSpdMoveAxis,
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
        .execute = &clientCarrierSpdMoveLocation,
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
            .{ .name = "axis", .optional = true },
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
            .{ .name = "axis", .optional = true },
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
        .execute = &clientAddLogInfo,
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
        .execute = &clientStartLogInfo,
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
        .execute = &clientRemoveLogInfo,
    });
    errdefer command.registry.orderedRemove("REMOVE_LOG_INFO");
    try command.registry.put(.{
        .name = "STATUS_LOG_INFO",
        .short_description = "Show the logging configuration(s).",
        .long_description =
        \\Show the logging configuration for each line, if any.
        ,
        .execute = &clientStatusLogInfo,
    });
    errdefer command.registry.orderedRemove("STATUS_LOG_INFO");
    try command.registry.put(.{
        .name = "PRINT_ERRORS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line" },
            .{ .name = "axis", .optional = true },
        },
        .short_description = "Print axis and driver errors.",
        .long_description =
        \\Print axis and driver errors on a line, if any. Providing axis
        \\prints axis and driver errors on the specified axis only, if any.
        ,
        .execute = &clientShowError,
    });
    errdefer command.registry.orderedRemove("PRINT_ERRORS");
}

pub fn deinit() void {
    disconnect() catch {};
    arena.deinit();
    network.deinit();
}

fn clientConnect(params: [][]const u8) !void {
    std.log.debug("{d}", .{params.len});
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
            std.log.err("{t}", .{e});
            try disconnect();
        }
    }
    var endpoint: struct { ip: []const u8, port: u16 } = .{
        .ip = IP_address,
        .port = port,
    };
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(u8, params[0], ":");
        endpoint.ip = iterator.next() orelse return error.MissingParameter;
        if (endpoint.ip.len > 63) return error.InvalidIPAddress;
        endpoint.port = try std.fmt.parseInt(
            u16,
            iterator.next() orelse return error.MissingParameter,
            0,
        );
    }
    std.log.info(
        "Trying to connect to {s}:{d}",
        .{ endpoint.ip, endpoint.port },
    );
    main_socket = try network.connectToHost(
        allocator,
        endpoint.ip,
        endpoint.port,
        .tcp,
    );
    if (params[0].len > 0) {
        port = endpoint.port;
        if (IP_address.len != endpoint.ip.len) {
            IP_address = try allocator.realloc(IP_address, endpoint.ip.len);
        }
        @memcpy(IP_address, endpoint.ip);
    }
    if (main_socket) |s| {
        std.log.info(
            "Connected to {f}",
            .{try s.getRemoteEndPoint()},
        );
        getLineConfig() catch |e| {
            std.log.err("{t}", .{e});
            return try disconnect();
        };
        assertAPIVersion() catch |e| {
            std.log.err("{t}", .{e});
            return try disconnect();
        };
    } else {
        std.log.err("Failed to connect to server", .{});
    }
}

/// Free all memory EXCEPT the IP_Address, so that client can reconnect
fn disconnect() error{ServerNotConnected}!void {
    if (main_socket) |s| {
        std.log.info(
            "Disconnecting from server {s}:{d}",
            .{ IP_address, port },
        );
        s.close();
        for (lines) |line| {
            allocator.free(line.axes);
            allocator.free(line.name);
            allocator.free(line.drivers);
        }
        allocator.free(lines);
        main_socket = null;
        lines = &.{};
    } else return error.ServerNotConnected;
}

/// Serve as a callback of a `DISCONNECT` command, requires parameter.
fn clientDisconnect(_: [][]const u8) error{ServerNotConnected}!void {
    try disconnect();
}

fn clientSetSpeed(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_speed = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_speed <= 0.0 or carrier_speed > 6.0) return error.InvalidSpeed;

    const line_idx = try matchLine(lines, line_name);
    lines[line_idx].velocity = @intFromFloat(carrier_speed * 10.0);

    std.log.info("Set speed to {d}m/s.", .{
        @as(f32, @floatFromInt(lines[line_idx].velocity)) / 10.0,
    });
}

fn clientSetAcceleration(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_acceleration = try std.fmt.parseFloat(f32, params[1]);
    if (carrier_acceleration <= 0.0 or carrier_acceleration > 24.5)
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
        main_socket,
    );
    defer fba.reset();
    const version = server.version orelse return error.InvalidResponse;
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
        main_socket,
    );
    defer fba.reset();
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
        main_socket,
    );
    defer fba.reset();
    defer response.deinit();

    const line_config = response.lines.items;
    log = try Log.init(@intCast(line_config.len));
    errdefer log.deinit();
    lines = try allocator.alloc(Line, line_config.len);
    errdefer allocator.free(lines);
    for (line_config, 0..) |line, line_idx| {
        try validateResponse(line);
        log.lines[line_idx].id = @intCast(line_idx + 1);
        lines[line_idx].axes = try allocator.alloc(
            Axis,
            @intCast(line.axes),
        );
        lines[line_idx].drivers = try allocator.alloc(
            Driver,
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
        lines[line_idx].length = .{
            .axis = @intFromFloat(line.length.?.axis * 1000),
            .carrier = @intFromFloat(line.length.?.carrier * 1000),
        };
        var num_axes: usize = 0;
        @memcpy(lines[line_idx].name, line.name.getSlice());
        for (0..@intCast(@divFloor(line.axes - 1, 3) + 1)) |driver_idx| {
            const start_num_axes = num_axes;
            for (0..3) |local_axis_idx| {
                lines[line_idx].axes[num_axes] = .{
                    .driver = &lines[line_idx].drivers[driver_idx],
                    .index = .{
                        .driver = @intCast(local_axis_idx),
                        .line = @intCast(num_axes),
                    },
                    .id = .{
                        .driver = @intCast(local_axis_idx + 1),
                        .line = @intCast(num_axes + 1),
                    },
                };
                num_axes += 1;
            }
            lines[line_idx].drivers[driver_idx] = .{
                .axes = lines[line_idx].axes[start_num_axes..num_axes],
                .line = &lines[line_idx],
                .index = @intCast(driver_idx),
                .id = @intCast(driver_idx + 1),
            };
        }
    }
    std.log.info(
        "Received the line configuration for the following line:",
        .{},
    );
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    for (lines) |line| {
        try stdout.interface.writeByte('\t');
        try stdout.interface.writeAll(line.name);
        try stdout.interface.writeByte('\n');
    }
    try stdout.interface.flush();
    for (lines) |line| {
        std.log.debug(
            "{s}:index {}:axes {}:drivers {}:acc {}:speed {}",
            .{
                line.name,
                line.index,
                line.axes.len,
                line.drivers.len,
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
        main_socket,
    );
    defer fba.reset();
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

fn clientShowError(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    const source: InfoRequest.System.source_union = .{
        .axis_range = b: {
            if (params[1].len > 0) {
                const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
                if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
                break :b .{ .start_id = axis_id, .end_id = axis_id };
            } else {
                const start = line.axes[0].id.line;
                const end = line.axes[line.axes.len - 1].id.line;
                break :b .{ .start_id = start, .end_id = end };
            }
        },
    };
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .axis = true,
            .driver = true,
            .source = source,
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    const axis_errors = system.axis_errors;
    if (axis_errors.items.len !=
        source.axis_range.end_id - source.axis_range.start_id + 1)
        return error.InvalidResponse;
    const driver_errors = system.driver_errors;
    if (driver_errors.items.len !=
        (source.axis_range.end_id - 1) / 3 - (source.axis_range.start_id - 1) / 3 + 1)
        return error.InvalidResponse;
    // Validate no null before starts printing
    for (axis_errors.items) |axis_err| {
        try validateResponse(axis_err);
    }
    for (driver_errors.items) |driver_err| {
        try validateResponse(driver_err);
    }
    for (axis_errors.items) |axis_err| {
        try printError(axis_err, .axis);
    }
    for (driver_errors.items) |driver_err| {
        try printError(driver_err, .driver);
    }
}

fn printError(err: anytype, comptime kind: enum { axis, driver }) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer stdout.interface.flush() catch {};
    const ti = @typeInfo(@TypeOf(err)).@"struct";
    {
        var has_id = false;
        inline for (ti.fields) |field| {
            if (std.mem.eql(u8, field.name, "id")) has_id = true;
        }
        if (!has_id) return error.InvalidResponse;
    }
    inline for (ti.fields) |field| {
        if (@typeInfo(field.type) == .@"struct") {
            const child = @field(err, field.name);
            const inner_ti = @typeInfo(field.type).@"struct";
            inline for (inner_ti.fields) |inner| {
                if (@field(child, inner.name))
                    try stdout.interface.print(
                        "{s}.{s} on {t} {d}",
                        .{ field.name, inner.name, kind, err.id },
                    );
            }
        } else if (@typeInfo(field.type) != .bool) {
            // no op if the field is not a boolean
        } else if (@field(err, field.name))
            try stdout.interface.print(
                "{s} on {t} {d}",
                .{ field.name, kind, err.id },
            );
    }
}

fn clientAxisInfo(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .axis = true,
            .source = .{
                .axis_range = .{
                    .start_id = @intCast(axis_id),
                    .end_id = @intCast(axis_id),
                },
            },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    const axis_infos = system.axis_infos;
    const axis_errors = system.axis_errors;
    if (axis_infos.items.len != axis_errors.items.len and
        axis_infos.items.len != 1)
        return error.InvalidResponse;
    const info = axis_infos.items[0];
    const err = axis_errors.items[0];
    try validateResponse(info);
    try validateResponse(err);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    _ = try nestedWrite("Axis info", info, 0, &stdout.interface);
    _ = try nestedWrite("Axis error", err, 0, &stdout.interface);
    try stdout.interface.flush();
}

fn clientDriverInfo(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const driver_id = try std.fmt.parseInt(Driver.Id, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (driver_id < 1 or driver_id > line.drivers.len) return error.InvalidDriver;
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .driver = true,
            .source = .{
                .driver_range = .{
                    .start_id = @intCast(driver_id),
                    .end_id = @intCast(driver_id),
                },
            },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    const driver_infos = system.driver_infos;
    const driver_errors = system.driver_errors;
    if (driver_infos.items.len != driver_errors.items.len and
        driver_errors.items.len != 1)
        return error.InvalidResponse;
    const info = driver_infos.items[0];
    const err = driver_errors.items[0];
    try validateResponse(info);
    try validateResponse(err);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    _ = try nestedWrite("Driver info", info, 0, &stdout.interface);
    _ = try nestedWrite("Driver error", err, 0, &stdout.interface);
    try stdout.interface.flush();
}

fn clientCarrierInfo(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    var ids = std.ArrayListAligned(
        u32,
        null,
    ).init(fba_allocator);
    try ids.append(carrier_id);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .carrier = true,
            .source = .{ .carriers = .{ .ids = ids } },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    var carriers = system.carrier_infos;
    if (carriers.items.len > 1) return error.InvalidResponse;
    const carrier = carriers.pop() orelse return error.CarrierNotFound;
    try validateResponse(carrier);
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    _ = try nestedWrite("Carrier", carrier, 0, &stdout.interface);
    try stdout.interface.flush();
}

fn clientAutoInitialize(params: [][]const u8) !void {
    defer fba.reset();
    var init_lines = std.ArrayListAligned(
        CommandRequest.AutoInitialize.Line,
        null,
    ).init(fba_allocator);
    if (params[0].len != 0) {
        var iterator = std.mem.tokenizeSequence(
            u8,
            params[0],
            ",",
        );
        while (iterator.next()) |line_name| {
            const line_idx = try matchLine(lines, line_name);
            const _line = lines[line_idx];
            const line: CommandRequest.AutoInitialize.Line = .{
                .line_id = @intCast(_line.id),
                .acceleration = @intCast(_line.acceleration),
                .velocity = @intCast(_line.velocity),
            };
            try init_lines.append(line);
        }
    } else {
        for (lines) |_line| {
            const line: CommandRequest.AutoInitialize.Line = .{
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
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientAxisCarrier(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
    const result_var: []const u8 = params[2];
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) return error.InvalidAxis;
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .carrier = true,
            .source = .{
                .axis_range = .{
                    .start_id = @intCast(axis_id),
                    .end_id = @intCast(axis_id),
                },
            },
        },
    };
    const system = sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    ) catch |e| {
        if (e == error.CarrierNotFound) {
            std.log.info("No carrier recognized on axis {d}.\n", .{axis_id});
            return;
        } else return e;
    };
    if (system.line_id != line.id)
        return error.InvalidResponse;
    var carriers = system.carrier_infos;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
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
    defer fba.reset();
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
        var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = null,
            },
        };
        const system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        const axis_infos = system.axis_infos;

        if (axis_infos.items.len != line.axes.len)
            return error.InvalidResponse;
        for (axis_infos.items) |axis| {
            if (axis.carrier_id == 0) continue;
            std.log.info(
                "Carrier {d} on line {s} axis {d}",
                .{ axis.carrier_id, line.name, axis.id },
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
                    .{axis.carrier_id},
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

fn clientAssertLocation(params: [][]const u8) !void {
    defer fba.reset();
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
    var ids = std.ArrayListAligned(
        u32,
        null,
    ).init(fba_allocator);
    try ids.append(carrier_id);
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .carrier = true,
            .source = .{ .carriers = .{ .ids = ids } },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    var carriers = system.carrier_infos;
    if (system.line_id != line.id)
        return error.InvalidResponse;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    const location = carrier.position;
    if (location < expected_location - location_thr or
        location > expected_location + location_thr)
        return error.UnexpectedCarrierLocation;
}

fn clientAxisReleaseServo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .release_control = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |axis| @intCast(axis) else null,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientClearErrors(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .clear_errors = .{
            .line_id = @intCast(line.id),
            .driver_id = if (axis_id) |id|
                @intCast(line.axes[id - 1].driver.id)
            else
                null,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientClearCarrierInfo(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .clear_carrier_info = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |id| @intCast(id) else null,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientResetSystem(_: [][]const u8) !void {
    for (lines) |line| {
        var command_msg = CommandRequest{
            .body = .{
                .clear_carrier_info = .{ .line_id = line.id },
            },
        };
        try sendCommandRequest(command_msg, fba_allocator, main_socket);
        command_msg.body = .{ .clear_errors = .{ .line_id = line.id } };
        try sendCommandRequest(command_msg, fba_allocator, main_socket);
        command_msg.body = .{ .stop_push_carrier = .{ .line_id = line.id } };
        try sendCommandRequest(command_msg, fba_allocator, main_socket);
        command_msg.body = .{ .stop_pull_carrier = .{ .line_id = line.id } };
        try sendCommandRequest(command_msg, fba_allocator, main_socket);
    }
}

fn clientCarrierLocation(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const result_var: []const u8 = params[2];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var ids = std.ArrayListAligned(
        u32,
        null,
    ).init(fba_allocator);
    try ids.append(carrier_id);
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .carrier = true,
            .source = .{ .carriers = .{ .ids = ids } },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    if (system.line_id != line.id)
        return error.InvalidResponse;
    var carriers = system.carrier_infos;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    std.log.info(
        "Carrier {d} location: {d} mm",
        .{ carrier.id, carrier.position },
    );
    if (result_var.len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(result_var, try std.fmt.bufPrint(
            &float_buf,
            "{d}",
            .{carrier.position},
        ));
    }
}

fn clientCarrierAxis(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    const carrier_id = try std.fmt.parseInt(u10, params[1], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var ids = std.ArrayListAligned(
        u32,
        null,
    ).init(fba_allocator);
    try ids.append(carrier_id);
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    info_msg.body = .{
        .system = .{
            .line_id = @intCast(line.id),
            .carrier = true,
            .source = .{ .carriers = .{ .ids = ids } },
        },
    };
    const system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    if (system.line_id != line.id)
        return error.InvalidResponse;
    var carriers = system.carrier_infos;
    const carrier = carriers.pop() orelse return error.InvalidResponse;
    if (carrier.axis) |axis| {
        std.log.info(
            "Carrier {d} axis: {}",
            .{ carrier.id, axis.main },
        );
        if (axis.auxiliary) |aux|
            std.log.info(
                "Carrier {d} axis: {}",
                .{ carrier.id, aux },
            );
    } else return error.InvalidResponse;
}

fn clientHallStatus(params: [][]const u8) !void {
    defer fba.reset();
    const line_name: []const u8 = params[0];
    var axis_id: ?Axis.Id.Line = null;
    const line_idx = try matchLine(lines, line_name);
    const line: Line = lines[line_idx];
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }

    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    if (axis_id) |id| {
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = .{
                    .axis_range = .{
                        .start_id = @intCast(id),
                        .end_id = @intCast(id),
                    },
                },
            },
        };
        var system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id) return error.InvalidResponse;
        const axis = system.axis_infos.pop() orelse return error.InvalidResponse;
        const hall = axis.hall_alarm orelse return error.InvalidResponse;
        std.log.info(
            "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
            .{
                axis.id,
                if (hall.back) "ON" else "OFF",
                if (hall.front) "ON" else "OFF",
            },
        );
    } else {
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = null,
            },
        };
        const system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id and
            system.axis_infos.items.len != line.axes.len)
            return error.InvalidResponse;
        // Validate response before starts printing
        for (system.axis_infos.items) |axis| try validateResponse(axis);
        // Starts printing hall status
        for (system.axis_infos.items) |axis| {
            std.log.info(
                "Axis {} Hall Sensor:\n\t BACK - {s}\n\t FRONT - {s}",
                .{
                    axis.id,
                    if (axis.hall_alarm.?.back) "ON" else "OFF",
                    if (axis.hall_alarm.?.front) "ON" else "OFF",
                },
            );
        }
    }
}

fn clientAssertHall(params: [][]const u8) !void {
    defer fba.reset();
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
        .system = .{
            .line_id = @intCast(line.id),
            .axis = true,
            .source = .{
                .axis_range = .{
                    .start_id = @intCast(axis_id),
                    .end_id = @intCast(axis_id),
                },
            },
        },
    };
    var system = try sendRequest(
        info_msg,
        fba_allocator,
        InfoResponse.System,
        main_socket,
    );
    if (system.line_id != line.id) return error.InvalidResponse;
    const axis = system.axis_infos.pop() orelse return error.InvalidResponse;
    const hall = axis.hall_alarm orelse return error.InvalidResponse;
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

fn clientCalibrate(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .calibrate = .{ .line_id = @intCast(line.id) },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    const link_axis: ?Direction = link: {
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
        } else break :link null;
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
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
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

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        defer fba.reset();
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        var ids = std.ArrayListAligned(
            u32,
            null,
        ).init(fba_allocator);
        try ids.append(carrier_id);
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{ .carriers = .{ .ids = ids } },
            },
        };
        var system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id)
            return error.InvalidResponse;
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == .CARRIER_STATE_ISOLATE_COMPLETED) return;
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
        defer fba.reset();
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        var ids = std.ArrayListAligned(
            u32,
            null,
        ).init(fba_allocator);
        try ids.append(carrier_id);
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{ .carriers = .{ .ids = ids } },
            },
        };
        var system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id)
            return error.InvalidResponse;
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == .CARRIER_STATE_MOVE_COMPLETED) return;
    }
}

fn clientCarrierPosMoveAxis(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const axis_id = try std.fmt.parseInt(Axis.Id.Line, params[2], 0);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

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
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientCarrierPosMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

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
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
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
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;
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
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_POSITION,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .axis = @intCast(axis_id) },
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientCarrierSpdMoveLocation(params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const carrier_id: u10 = try std.fmt.parseInt(u10, params[1], 0);
    const location: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (carrier_id == 0 or carrier_id > 254) return error.InvalidCarrierId;
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

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
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[3]))
        true
    else
        return error.InvalidCasConfiguration;

    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();
    command_msg.body = .{
        .move_carrier = .{
            .line_id = @intCast(line.id),
            .carrier_id = carrier_id,
            .velocity = @intCast(lines[line_idx].velocity),
            .acceleration = @intCast(lines[line_idx].acceleration),
            .target = .{ .distance = distance },
            .disable_cas = disable_cas,
            .control_kind = .CONTROL_VELOCITY,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
        std.log.info("id: {}, target: {}", .{
            id,
            line.length.axis * (id - 1) + 150,
        });
        if (id == 0 or id > line.axes.len) return error.InvalidAxis;
        command_axis = @intCast(id);
        command_msg.body = .{
            .move_carrier = .{
                .line_id = @intCast(line.id),
                .carrier_id = carrier_id,
                .velocity = @intCast(lines[line_idx].velocity),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{
                    .location = @as(f32, @floatFromInt(line.length.axis * (id - 1))) + 150.0,
                },
                .disable_cas = true,
                .control_kind = .CONTROL_POSITION,
            },
        };
        try sendCommandRequest(
            command_msg,
            fba_allocator,
            main_socket,
        );
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
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
        command_msg.body = .{
            .move_carrier = .{
                .line_id = @intCast(line.id),
                .carrier_id = carrier_id,
                .velocity = @intCast(lines[line_idx].velocity),
                .acceleration = @intCast(lines[line_idx].acceleration),
                .target = .{
                    .location = @as(f32, @floatFromInt(line.length.axis * (id - 1))) - 150.0,
                },
                .disable_cas = true,
                .control_kind = .CONTROL_POSITION,
            },
        };
        try sendCommandRequest(
            command_msg,
            fba_allocator,
            main_socket,
        );
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

    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;

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
            .transition = blk: {
                if (destination) |loc| break :blk .{
                    .control_kind = .CONTROL_POSITION,
                    .disable_cas = disable_cas,
                    .target = .{
                        .location = loc,
                    },
                } else break :blk null;
            },
        },
    };

    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
    const disable_cas = if (params[4].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("true", params[4]))
        true
    else
        return error.InvalidCasConfiguration;

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
            .transition = blk: {
                if (destination) |loc| break :blk .{
                    .control_kind = .CONTROL_POSITION,
                    .disable_cas = disable_cas,
                    .target = .{
                        .location = loc,
                    },
                } else break :blk null;
            },
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
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

    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var wait_timer = try std.time.Timer.start();
    var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
    defer info_msg.deinit();
    while (true) {
        defer fba.reset();
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        var ids = std.ArrayListAligned(
            u32,
            null,
        ).init(fba_allocator);
        try ids.append(carrier_id);
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .carrier = true,
                .source = .{ .carriers = .{ .ids = ids } },
            },
        };
        var system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id)
            return error.InvalidResponse;
        const carrier = system.carrier_infos.pop() orelse return error.InvalidResponse;
        if (carrier.state == .CARRIER_STATE_PULL_COMPLETED) return;
    }
}

fn clientCarrierStopPull(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();

    command_msg.body = .{
        .stop_pull_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |axis| @intCast(axis) else null,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
}

fn clientCarrierStopPush(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(lines, line_name);
    const line = lines[line_idx];
    var axis_id: ?Axis.Id.Line = null;
    if (params[1].len > 0) {
        const axis = try std.fmt.parseInt(Axis.Id.Line, params[1], 0);
        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;
        axis_id = axis;
    }
    var command_msg: CommandRequest = CommandRequest.init(fba_allocator);
    defer command_msg.deinit();

    command_msg.body = .{
        .stop_push_carrier = .{
            .line_id = @intCast(line.id),
            .axis_id = if (axis_id) |axis| @intCast(axis) else null,
        },
    };
    try sendCommandRequest(
        command_msg,
        fba_allocator,
        main_socket,
    );
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
        defer fba.reset();
        if (timeout != 0 and
            wait_timer.read() > timeout * std.time.ns_per_ms)
            return error.WaitTimeout;
        try command.checkCommandInterrupt();
        var info_msg: InfoRequest = InfoRequest.init(fba_allocator);
        info_msg.body = .{
            .system = .{
                .line_id = @intCast(line.id),
                .axis = true,
                .source = .{
                    .axis_range = .{
                        .start_id = @intCast(axis.id.line),
                        .end_id = @intCast(axis.id.line),
                    },
                },
            },
        };
        var system = try sendRequest(
            info_msg,
            fba_allocator,
            InfoResponse.System,
            main_socket,
        );
        if (system.line_id != line.id) return error.InvalidResponse;
        const axis_info = system.axis_infos.pop() orelse return error.InvalidResponse;
        const carrier = axis_info.carrier_id;
        const axis_alarms = axis_info.hall_alarm orelse return error.InvalidResponse;
        const wait_push = axis_info.waiting_push;
        const wait_pull = axis_info.waiting_pull;
        if (carrier == 0 and !axis_alarms.back and !axis_alarms.front and
            !wait_pull and !wait_push)
        {
            break;
        }
    }
}

fn clientAddLogInfo(params: [][]const u8) !void {
    const line_name = params[0];
    const line_idx = try matchLine(lines, line_name);
    const kind = params[1];
    if (kind.len == 0) return error.MissingParameter;
    const line = lines[line_idx];
    var log_config = Log.Config{ .id = line.id };
    const range = params[2];
    if (range.len > 0) {
        var range_iterator = std.mem.tokenizeSequence(u8, range, ":");
        log_config.axis_id_range = .{
            .start = try std.fmt.parseInt(
                Axis.Id.Line,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
            .end = try std.fmt.parseInt(
                Axis.Id.Line,
                range_iterator.next() orelse return error.MissingParameter,
                0,
            ),
        };
    } else {
        log_config.axis_id_range = .{ .start = 1, .end = @intCast(line.axes.len) };
    }
    if ((log_config.axis_id_range.start < 1 and
        log_config.axis_id_range.start > line.axes.len) or
        (log_config.axis_id_range.end < 1 and
            log_config.axis_id_range.end > line.axes.len))
        return error.InvalidAxis;
    if (std.ascii.eqlIgnoreCase("all", kind)) {
        log_config.axis = true;
        log_config.driver = true;
    } else {
        const ti = @typeInfo(Log.Kind).@"enum";
        inline for (ti.fields) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, kind)) {
                @field(log_config, field.name) = true;
            }
        }
        if (!log_config.axis and !log_config.driver)
            return error.InvalidKind;
    }
    log.lines[line_idx] = log_config;
    // Show the current logging configuration status
    try clientStatusLogInfo(&[_][]u8{});
}

fn clientStartLogInfo(params: [][]const u8) !void {
    errdefer {
        log.duration = 0;
        allocator.free(log.path);
    }
    log.duration = try std.fmt.parseFloat(f64, params[0]);
    const path = params[1];
    log.path = if (path.len > 0) path else p: {
        var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(timestamp / std.time.s_per_day);
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(timestamp % std.time.s_per_day);
        const time = try chrono.Time.fromNumSecondsFromMidnight(
            time_day,
            0,
        );
        break :p try std.fmt.allocPrint(
            allocator,
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
    const log_thread = try std.Thread.spawn(.{}, Log.start, .{});
    log_thread.detach();
}

fn clientStatusLogInfo(_: [][]const u8) !void {
    // Show the current logging configuration status
    std.log.info("Logging configuration:", .{});
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer stdout.interface.flush() catch {};
    for (log.lines) |line| {
        if (!line.axis and !line.driver) continue;
        try stdout.interface.print("Line {s}:", .{lines[line.id - 1].name});
        const ti = @typeInfo(@TypeOf(line)).@"struct";
        var set = false;
        inline for (ti.fields) |field| {
            if (@typeInfo(field.type) != .bool) {
                // Skip
            } else if (@field(line, field.name)) {
                if (set) try stdout.interface.writeByte(',');
                try stdout.interface.print(" {s}", .{field.name});
                set = true;
            }
        }
        const range = line.axis_id_range;
        if (range.start == range.end)
            try stdout.interface.print(" (axis {d})", .{range.start})
        else
            try stdout.interface.print(
                " (axis {d} to {d})",
                .{
                    line.axis_id_range.start,
                    line.axis_id_range.end,
                },
            );
        try stdout.interface.writeByte('\n');
    }
}

fn clientRemoveLogInfo(params: [][]const u8) !void {
    if (params[0].len > 0) {
        const line_name = params[0];
        const line_idx = try matchLine(lines, line_name);
        log.lines[line_idx] = .{};
    } else {
        for (log.lines) |*line| {
            line.* = .{};
        }
    }
    // Show the current logging configuration status
    try clientStatusLogInfo(&[_][]u8{});
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
    socket: ?network.Socket,
) !T {
    const s = if (socket) |_s| _s else return error.ServerNotConnected;
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
}

/// Send a command request and wait for its response to arrive
fn sendCommandRequest(
    command_msg: CommandRequest,
    a: std.mem.Allocator,
    s: ?network.Socket,
) !void {
    const command_id = try sendRequest(
        command_msg,
        a,
        u32,
        s,
    );
    var info_msg: InfoRequest = InfoRequest.init(a);
    defer info_msg.deinit();
    while (true) {
        command.checkCommandInterrupt() catch |e| {
            var remove_command: CommandRequest = CommandRequest.init(a);
            defer remove_command.deinit();
            remove_command.body = .{
                .clear_command = .{ .command_id = command_id },
            };
            _ = sendRequest(
                remove_command,
                a,
                bool,
                s,
            ) catch |err| {
                std.log.debug("{?f}", .{@errorReturnTrace()});
                std.log.info("{t}", .{err});
            };
            return e;
        };
        info_msg.body = .{
            .command = .{ .id = command_id },
        };
        var commands = sendRequest(
            info_msg,
            a,
            InfoResponse.Commands,
            s,
        ) catch |e| {
            if (e == error.CommandStopped) {
                var remove_command: CommandRequest = CommandRequest.init(a);
                defer remove_command.deinit();
                remove_command.body = .{
                    .clear_command = .{ .command_id = command_id },
                };
                _ = sendRequest(
                    remove_command,
                    a,
                    bool,
                    s,
                ) catch |err| {
                    std.log.debug("{?f}", .{@errorReturnTrace()});
                    std.log.info("{t}", .{err});
                };
                return e;
            } else return e;
        };
        defer commands.deinit();
        if (commands.commands.items.len > 1) return error.InvalidResponse;
        const comm = commands.commands.pop() orelse return error.InvalidResponse;
        switch (comm.status) {
            .STATUS_PROGRESSING, .STATUS_QUEUED => {}, // continue the loop
            .STATUS_COMPLETED => break,
            .STATUS_FAILED => {
                return switch (comm.error_response orelse return error.UnexpectedResponse) {
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
    return switch (response.body orelse return error.InvalidResponse) {
        .command => |command_response| blk: switch (command_response.body orelse return error.InvalidResponse) {
            .command_id => |r| if (@TypeOf(r) == T) break :blk r else error.UnexpectedResponse,
            .request_error => |r| {
                switch (r) {
                    .COMMAND_REQUEST_ERROR_UNSPECIFIED => break :blk error.UnexpectedResponse,
                    .COMMAND_REQUEST_ERROR_INVALID_LINE => break :blk error.InvalidLine,
                    .COMMAND_REQUEST_ERROR_INVALID_AXIS => break :blk error.InvalidAxis,
                    .COMMAND_REQUEST_ERROR_CARRIER_NOT_FOUND => break :blk error.CarrierNotFound,
                    .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED => break :blk error.CCLinkDisconnected,
                    .COMMAND_REQUEST_ERROR_INVALID_ACCELERATION => break :blk error.InvalidAcceleration,
                    .COMMAND_REQUEST_ERROR_INVALID_VELOCITY => break :blk error.InvalidSpeed,
                    .COMMAND_REQUEST_ERROR_OUT_OF_MEMORY => break :blk error.ServerRunningOutOfMemory,
                    .COMMAND_REQUEST_ERROR_MISSING_PARAMETER => break :blk error.MissingParameter,
                    .COMMAND_REQUEST_ERROR_INVALID_DIRECTION => break :blk error.InvalidDirection,
                    .COMMAND_REQUEST_ERROR_INVALID_LOCATION => break :blk error.InvalidLocation,
                    .COMMAND_REQUEST_ERROR_INVALID_DISTANCE => break :blk error.InvalidDistance,
                    .COMMAND_REQUEST_ERROR_INVALID_CARRIER => break :blk error.InvalidCarrier,
                    .COMMAND_REQUEST_ERROR_COMMAND_PROGRESSING => break :blk error.CommandProgressing,
                    .COMMAND_REQUEST_ERROR_COMMAND_NOT_FOUND => break :blk error.CommandNotFound,
                    .COMMAND_REQUEST_ERROR_MAXIMUM_AUTO_INITIALIZE_EXCEEDED => break :blk error.MaximumAutoInitializeExceeded,
                    .COMMAND_REQUEST_ERROR_INVALID_DRIVER => break :blk error.InvalidDriver,
                    _ => unreachable,
                }
            },
            .command_operation => |r| switch (r) {
                .COMMAND_STATUS_UNSPECIFIED => break :blk error.UnexpectedResponse,
                .COMMAND_STATUS_COMPLETED => if (T == bool) break :blk true else error.UnexpectedResponse,
                _ => unreachable,
            },
        },
        .core => |core_response| switch (core_response.body orelse return error.InvalidResponse) {
            .request_error => |r| switch (r) {
                .CORE_REQUEST_ERROR_UNSPECIFIED => error.UnexpectedResponse,
                .CORE_REQUEST_ERROR_REQUEST_UNKNOWN => error.RequestUnknown,
                _ => unreachable,
            },
            .api_version => |r| if (@TypeOf(r) == T)
                r
            else
                error.UnexpectedResponse,
            inline .server, .line_config => |r| if (@TypeOf(r) == T)
                try r.dupe(a)
            else
                error.UnexpectedResponse,
        },
        .info => |info_response| switch (info_response.body orelse return error.InvalidResponse) {
            .request_error => |r| switch (r) {
                .INFO_REQUEST_ERROR_UNSPECIFIED => error.UnexpectedResponse,
                .INFO_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .INFO_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .INFO_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
                .INFO_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                .INFO_REQUEST_ERROR_CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .INFO_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                .INFO_REQUEST_ERROR_COMMAND_NOT_FOUND => error.CommandNotFound,
                _ => unreachable,
            },
            inline .system, .commands => |body_kind| if (@TypeOf(body_kind) == T)
                try body_kind.dupe(a)
            else
                return error.UnexpectedResponse,
        },
        .request_error => |r| switch (r) {
            .MMC_REQUEST_ERROR_UNSPECIFIED => error.UnexpectedResponse,
            .MMC_REQUEST_ERROR_INVALID_MESSAGE => error.RequestUnknown,
            _ => unreachable,
        },
    };
}

pub fn nestedWrite(
    name: []const u8,
    val: anytype,
    indent: usize,
    writer: *std.Io.Writer,
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
                    writer,
                );
            } else {
                try writer.splatBytesAll("    ", indent);
                written_bytes += 4 * indent;
                try writer.print("{s}: ", .{name});
                written_bytes += name.len + 2;
                try writer.print("None,\n", .{});
                written_bytes += std.fmt.count("None,\n", .{});
            }
        },
        .@"struct" => {
            try writer.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try writer.print("{s}: {{\n", .{name});
            written_bytes += name.len + 4;
            inline for (ti.@"struct".fields) |field| {
                if (field.name[0] == '_') {
                    continue;
                }
                written_bytes += try nestedWrite(
                    field.name,
                    @field(val, field.name),
                    indent + 1,
                    writer,
                );
            }
            try writer.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try writer.writeAll("},\n");
            written_bytes += 3;
        },
        .bool, .int => {
            try writer.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try writer.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try writer.print("{},\n", .{val});
            written_bytes += std.fmt.count("{},\n", .{val});
        },
        .float => {
            try writer.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try writer.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try writer.print("{d},\n", .{val});
            written_bytes += std.fmt.count("{d},\n", .{val});
        },
        .@"enum" => {
            try writer.splatBytesAll("    ", indent);
            written_bytes += 4 * indent;
            try writer.print("{s}: ", .{name});
            written_bytes += name.len + 2;
            try writer.print("{t},\n", .{val});
            written_bytes += std.fmt.count("{t},\n", .{val});
        },
        .@"union" => {
            switch (val) {
                inline else => |_, tag| {
                    const union_val = @field(val, @tagName(tag));
                    try writer.splatBytesAll("    ", indent);
                    written_bytes += 4 * indent;
                    try writer.print("{s}: ", .{name});
                    written_bytes += name.len + 2;
                    try writer.print("{d},\n", .{union_val});
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
        // std.log.debug("revents: {}", .{poll_fd[0].revents});
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
    // std.log.debug(
    //     "received msg: {any}, length: {}",
    //     .{ buffer[0..msg_size], msg_size },
    // );
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
    var writer = socket.writer(&.{});
    writer.interface.writeAll(msg) catch |e| {
        try disconnect();
        return e;
    };
}

/// Zig-protobuf cast the message into an optional for a struct or union type.
/// Validate the optional struct and union is not null.
fn validateResponse(item: anytype) error{InvalidResponse}!void {
    const ti = @typeInfo(@TypeOf(item));
    switch (ti) {
        .@"struct" => {
            inline for (ti.@"struct".fields) |field| {
                if (@typeInfo(field.type) == .optional) {
                    const opt_ti = @typeInfo(field.type).optional;
                    switch (@typeInfo(opt_ti.child)) {
                        .@"struct" => {
                            if (@field(item, field.name) == null)
                                return error.InvalidResponse
                            else
                                try validateResponse(@field(item, field.name).?);
                        },
                        .@"union" => {
                            if (@field(item, field.name) == null)
                                return error.InvalidResponse
                            else
                                try validateResponse(@field(item, field.name).?);
                        },
                        // Ignore other child type. Shall be validated on the caller site
                        else => {},
                    }
                }
            }
        },
        .@"union" => {
            switch (item) {
                else => |active| {
                    const active_ti = @typeInfo(@TypeOf(active));
                    switch (active_ti) {
                        .optional => {
                            switch (@typeInfo(active_ti.optional.child)) {
                                .@"struct" => {
                                    if (active == null)
                                        return error.InvalidResponse
                                    else
                                        try validateResponse(active.?);
                                },
                                .@"union" => {
                                    if (active == null)
                                        return error.InvalidResponse
                                    else
                                        try validateResponse(active.?);
                                },
                                // Ignore other child type. Shall be validated on the caller site
                                else => {},
                            }
                        },
                        else => {},
                    }
                },
            }
        },
        inline else => @compileError("Item is not a struct or union"),
    }
}

test validateResponse {
    // The lowest level test
    var item = InfoResponse.System.Axis.Info.init(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidResponse,
        validateResponse(item),
    );
    item.hall_alarm = .{};
    try validateResponse(item);
    // Info level test
    var info = InfoResponse.init(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidResponse,
        validateResponse(info),
    );
    info.body = .{
        .system = .init(std.testing.allocator),
    };
    try validateResponse(info);
}
