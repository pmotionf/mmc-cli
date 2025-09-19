const Log = @This();

const std = @import("std");
const CircularBufferAlloc =
    @import("../../circular_buffer.zig").CircularBufferAlloc;
const api_helper = @import("api.zig");
const SystemResponse = api_helper.api.info_msg.Response.System;
const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");
const main = @import("../../main.zig");
/// Determine whether the log has been started or not. Deinit function behavior
/// depends on this flag.
pub var start = std.atomic.Value(bool).init(false);
// NOTE: The following buffer differ from the client buffer as they are working
//       on different thread.
/// Reader buffer for network stream
pub var reader_buf: [4096]u8 = undefined;
/// Writer buffer for network stream
pub var writer_buf: [4096]u8 = undefined;

allocator: std.mem.Allocator,
path: ?[]const u8,
configs: []Config,
data: ?CircularBufferAlloc(Data),
endpoint: client.zignet.Endpoint,

/// Kind of info to log
pub const Kind = enum { axis, driver };
/// Logging configuration for each line. Only the latest configuration
/// will be used for logging process.
pub const Config = struct {
    /// Line ID to be logged
    id: client.Line.Id,
    /// Line name to be logged
    name: []u8,
    /// Flag for logging axis.
    axis: bool,
    /// Flag for logging driver.
    driver: bool,
    /// Inclusive axis range of the line to be logged.
    axis_id_range: Range,

    pub const Range = struct { start: u32, end: u32 };

    pub fn init(
        self: *Config,
        allocator: std.mem.Allocator,
        id: client.Line.Id,
        name: []const u8,
    ) !void {
        self.id = id;
        self.name = try allocator.dupe(u8, name);
        self.axis = false;
        self.driver = false;
        self.axis_id_range = .{ .start = 0, .end = 0 };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.name = &.{};
        self.id = 0;
        self.axis = false;
        self.driver = false;
        self.axis_id_range = .{ .start = 0, .end = 0 };
    }
};

// TODO: Make a dynamic allocation for the log and compare the time with
//       buffer
const max = struct {
    const driver = 64 * 4;
    const axis = driver * 3;
};

/// One iteration of logged data
pub const Data = struct {
    timestamp: f64 = 0,
    axes: [max.axis]Axis = [_]Axis{
        std.mem.zeroInit(Axis, .{}),
    } ** max.axis,
    drivers: [max.driver]Driver,

    pub const Axis = struct {
        hall: struct { back: bool, front: bool },
        motor_enabled: bool,
        pulling: bool,
        pushing: bool,
        carrier: Carrier,
        err: Error,
        pub const Carrier = struct {
            id: u10,
            position: f32,
            state: SystemResponse.Carrier.Info.State,
            cas: struct { enabled: bool, triggered: bool },
        };
        pub const Error = struct {
            overcurrent: bool,
        };
    };

    pub const Driver = struct {
        connected: bool,
        available: bool,
        servo_enabled: bool,
        stopped: bool,
        paused: bool,
        err: Error,
        pub const Error = struct {
            control_loop_max_time_exceeded: bool,
            inverter_overheat: bool,
            power: struct { overvoltage: bool, undervoltage: bool },
            comm: struct { from_prev: bool, from_next: bool },
        };
    };

    /// Reset the logged value of axes and drivers
    pub fn reset(self: *Data) void {
        self.axes = [_]Axis{std.mem.zeroInit(
            Axis,
            .{},
        )} ** max.axis;
        self.drivers = [_]Driver{std.mem.zeroInit(
            Driver,
            .{},
        )} ** max.driver;
        self.timestamp = 0;
    }

    /// Get the data from the server and fill the logging memory with the response.
    fn get(
        self: *Data,
        /// Allocator for encoding, decoding, sending, and receiving the message
        /// from the server.
        allocator: std.mem.Allocator,
        /// Logging configurations
        configs: []Config,
        socket: *client.zignet.Socket,
    ) !void {
        var axis_idx: usize = 0;
        var driver_idx: usize = 0;
        for (configs) |config| {
            if (config.axis_id_range.start == 0) continue;
            {
                try socket.waitToWrite(command.checkCommandInterrupt);
                var writer = socket.writer(&writer_buf);
                try api_helper.request.info.system.encode(
                    allocator,
                    &writer.interface,
                    .{
                        .line_id = config.id,
                        .axis = config.axis,
                        .carrier = if (config.axis) true else false,
                        .driver = config.driver,
                        .source = .{
                            .axis_range = .{
                                .start_id = config.axis_id_range.start,
                                .end_id = config.axis_id_range.end,
                            },
                        },
                    },
                );
                try writer.interface.flush();
            }
            try socket.waitToRead(command.checkCommandInterrupt);
            var reader = socket.reader(&reader_buf);
            var response = try api_helper.response.info.system.decode(
                allocator,
                &reader.interface,
            );
            defer response.deinit(allocator);
            const axis_infos = response.axis_infos;
            const axis_errors = response.axis_errors;
            const driver_infos = response.driver_infos;
            const driver_errors = response.driver_errors;
            const carriers = response.carrier_infos;
            // Parse axes informations
            for (
                axis_infos.items,
                axis_errors.items,
            ) |axis_info, axis_err| {
                if (axis_info.id != axis_err.id) return error.InvalidResponse;
                self.axes[axis_idx] = .{
                    .hall = .{
                        .front = axis_info.hall_alarm.?.front,
                        .back = axis_info.hall_alarm.?.back,
                    },
                    .motor_enabled = axis_info.motor_enabled,
                    .pulling = axis_info.waiting_pull,
                    .pushing = axis_info.waiting_push,
                    .err = .{
                        .overcurrent = axis_err.overcurrent,
                    },
                    .carrier = std.mem.zeroInit(
                        Log.Data.Axis.Carrier,
                        .{},
                    ),
                };
                axis_idx += 1;
            }
            // Parse carrier information response to axis.carrier
            for (carriers.items) |_carrier| {
                const _axis = _carrier.axis.?;
                const ti = @typeInfo(@TypeOf(_axis)).@"struct";
                inline for (ti.fields) |field| {
                    const axis = if (@typeInfo(field.type) == .optional) b: {
                        if (@field(_axis, field.name)) |id| {
                            break :b id - 1;
                        } else break;
                    } else @field(_axis, field.name) - 1;
                    self.axes[axis].carrier = .{
                        .id = @intCast(_carrier.id),
                        .position = _carrier.position,
                        .state = _carrier.state,
                        .cas = .{
                            .enabled = _carrier.cas.?.enabled,
                            .triggered = _carrier.cas.?.triggered,
                        },
                    };
                }
            }
            for (
                driver_infos.items,
                driver_errors.items,
            ) |driver_info, driver_err| {
                self.drivers[driver_idx] = .{
                    .connected = driver_info.connected,
                    .available = driver_info.available,
                    .servo_enabled = driver_info.servo_enabled,
                    .stopped = driver_info.servo_enabled,
                    .paused = driver_info.paused,
                    .err = .{
                        .control_loop_max_time_exceeded = driver_err.control_loop_time_exceeded,
                        .inverter_overheat = driver_err.inverter_overheat,
                        .power = .{
                            .overvoltage = driver_err.power_error.?.overvoltage,
                            .undervoltage = driver_err.power_error.?.undervoltage,
                        },
                        .comm = .{
                            .from_prev = driver_err.communication_error.?.from_prev,
                            .from_next = driver_err.communication_error.?.from_next,
                        },
                    },
                };
                driver_idx += 1;
            }
        }
    }
};

/// Assign the allocator and allocate line configurations. Call deinit to release
/// the memory
pub fn init(
    /// Allocator for allocating the memory for logging data and configuration
    allocator: std.mem.Allocator,
    /// Number of lines from mcl configuration
    lines: []client.Line,
    endpoint: client.zignet.Endpoint,
) !Log {
    return .{
        .allocator = allocator,
        .configs = try allocator.alloc(Config, lines.len),
        .endpoint = endpoint,
        .path = null,
        .data = null,
    };
}

pub fn deinit(self: *Log) void {
    for (self.configs) |*config| {
        config.deinit(self.allocator);
    }
    self.allocator.free(self.configs);
    self.endpoint = undefined;
    self.reset();
}

/// Clear all memory except congfigs, so that user can start logging instantly.
pub fn reset(self: *Log) void {
    if (self.path) |path| {
        self.allocator.free(path);
        self.path = null;
    }
    if (self.data) |*data| {
        data.deinit();
        self.data = null;
    }
}

/// Show the current logging configuration
pub fn status(self: *Log) !void {
    std.log.info("Logging configuration:", .{});
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    defer stdout.interface.flush() catch {};
    for (self.configs) |line| {
        if (!line.axis and !line.driver) continue;
        try stdout.interface.print("Line {s}:", .{client.lines[line.id - 1].name});
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

/// Write the logged data into the logging file
fn write(
    self: *Log,
    writer: *std.Io.Writer,
    duration: f64,
    last_timestamp: f64,
) !void {
    // Write header for the logging file
    try writer.writeAll("timestamp,");
    for (self.configs) |config| {
        var buf: [64]u8 = undefined;
        if (!config.axis and !config.driver) continue;
        if (config.driver) {
            const start_id = (config.axis_id_range.start - 1) / 3 + 1;
            const end_id = (config.axis_id_range.end - 1) / 3 + 1;
            for (start_id..end_id + 1) |id| {
                try writeHeaders(
                    writer,
                    try std.fmt.bufPrint(
                        &buf,
                        "{s}_driver{d}",
                        .{ config.name, id },
                    ),
                    "",
                    Log.Data.Driver,
                );
            }
        }
        if (config.axis) {
            const start_id = config.axis_id_range.start;
            const end_id = config.axis_id_range.end;
            for (start_id..end_id + 1) |id| {
                try writeHeaders(
                    writer,
                    try std.fmt.bufPrint(
                        &buf,
                        "{s}_axis{d}",
                        .{ config.name, id },
                    ),
                    "",
                    Log.Data.Axis,
                );
            }
        }
    }
    // Write the data to the logging file
    while (self.data.?.readItem()) |data| {
        if (last_timestamp - data.timestamp > duration) continue;
        try writer.writeByte('\n');
        try writer.print(
            "{d},",
            .{data.timestamp},
        );
        for (self.configs) |config| {
            if (config.driver) {
                const start_id = (config.axis_id_range.start - 1) / 3 + 1;
                const end_id = (config.axis_id_range.end - 1) / 3 + 1;
                for (start_id - 1..end_id) |idx| {
                    try writeValues(writer, data.drivers[idx]);
                }
            }
            if (config.axis) {
                const start_id = config.axis_id_range.start;
                const end_id = config.axis_id_range.end;
                for (start_id - 1..end_id) |idx| {
                    try writeValues(writer, data.axes[idx]);
                }
            }
        }
    }
}

/// Handler for the whole logging process
pub fn handler(duration: f64) !void {
    Log.start.store(true, .monotonic);
    defer Log.start.store(false, .monotonic);
    defer client.log.reset();
    // Assumption: The register from mcl is updated every 3 ms. Requesting
    //             data with interval reducing the server loads.
    const mcl_update = 3;
    const logging_size_float =
        duration * @as(f64, @floatFromInt(std.time.ms_per_s)) / mcl_update;
    if (std.math.isNan(logging_size_float) or
        std.math.isInf(logging_size_float) or
        !std.math.isFinite(logging_size_float) or
        logging_size_float <= 0) return error.InvalidDuration;
    var initialized = false;
    for (client.log.configs) |line| {
        if (line.axis or line.driver) {
            initialized = true;
            break;
        }
    }
    if (!initialized) return error.NoConfiguredLogging;
    std.log.info("The registers will be logged to {s}", .{client.log.path.?});
    const log_file = try std.fs.cwd().createFile(client.log.path.?, .{});
    defer log_file.close();
    const logging_size = @as(usize, @intFromFloat(logging_size_float));
    var socket = try client.zignet.Socket.connect(client.log.endpoint);
    defer socket.close();
    var data = std.mem.zeroInit(Data, .{});
    client.log.data = try .initCapacity(
        client.log.allocator,
        logging_size,
    );
    // TODO: This approach make checkError cannot be used by other thread.
    //       Find a better approach.
    // Remove any previous detected error.
    command.checkError() catch {};
    defer std.log.debug("Logging stopped", .{});
    std.log.debug("Logging started", .{});
    const log_time_start = std.time.microTimestamp();
    var timer = try std.time.Timer.start();
    var timestamp: f64 = undefined;
    while (true) {
        if (main.exit.load(.monotonic)) break;
        // Check if there is an error after the log started, including the
        // command cancellation.
        command.checkError() catch |e| {
            std.log.debug("{t}", .{e});
            std.log.debug("{?f}", .{@errorReturnTrace()});
            break;
        };
        while (timer.read() < mcl_update * std.time.ns_per_ms) {}
        timestamp = @as(
            f64,
            @floatFromInt(std.time.microTimestamp() - log_time_start),
        ) / std.time.us_per_s;
        timer.reset();
        data.timestamp = timestamp;
        data.get(
            client.log.allocator,
            client.log.configs,
            &socket,
        ) catch |e| {
            std.log.debug("{t}", .{e});
            std.log.debug("{?f}", .{@errorReturnTrace()});
            // NOTE: Should the main thread be notified to stop any running
            //       command? Example use case: When execute a file, if the
            //       logging failed, it is hard to notice that the logging
            //       is finished while keep executing commands.
            break;
        };
        defer data.reset();
        client.log.data.?.writeItemOverwrite(data);
    }
    var log_writer = log_file.writer(&.{});
    try client.log.write(&log_writer.interface, duration, timestamp);
    try log_writer.interface.flush();
    std.log.info("Logging data is saved successfully.", .{});
}
