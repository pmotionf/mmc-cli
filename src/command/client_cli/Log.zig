const Log = @This();

const std = @import("std");
const CircularBufferAlloc =
    @import("../../circular_buffer.zig").CircularBufferAlloc;
const api_helper = @import("api.zig");
const SystemResponse = api_helper.api.info_msg.Response.System;
const client = @import("../client_cli.zig");
const command = @import("../../command.zig");
const Network = @import("Network.zig");

allocator: std.mem.Allocator,
path: []const u8,
configs: []Config,
timestamps: CircularBufferAlloc(u64),
data: CircularBufferAlloc([]Data.Line),
endpoint: Network.Endpoint,

/// Kind of info to log
pub const Kind = enum { axis, driver };
/// Logging configuration for each line. Only the latest configuration
/// will be used for logging process.
pub const Config = struct {
    /// Line ID to be logged
    id: client.Line.Id = 0,
    /// Flag for logging axis.
    axis: bool = false,
    /// Flag for logging driver.
    driver: bool = false,
    /// Inclusive axis range of the line to be logged.
    axis_id_range: struct {
        start: client.Axis.Id.Line = 0,
        end: client.Axis.Id.Line = 0,
    } = .{},
};

/// One iteration of logged data
pub const Data = struct {
    timestamp: u64 = 0,
    lines: []Data.Line,

    pub const Line = struct {
        axes: []Data.Line.Axis,
        drivers: []Data.Line.Driver,
        pub const Axis = struct {
            id: client.Axis.Id.Line,
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
            id: client.Driver.Id,
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

        pub fn init(allocator: std.mem.Allocator, config: Config) !Line {
            var result: Line = undefined;
            if (config.axis)
                result.axes = try allocator.alloc(
                    Data.Line.Axis,
                    config.axis_id_range.end - config.axis_id_range.start + 1,
                );
            if (config.driver)
                result.drivers = try allocator.alloc(
                    Data.Line.Driver,
                    config.axis_id_range.end / 3 - config.axis_id_range.start / 3 + 1,
                );
            return result;
        }

        pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
            allocator.free(self.axes);
            allocator.free(self.drivers);
        }
    };

    /// Allocate memory for storing one iteration of logged data before written
    /// to full logging data. Call deinit to release the memory.
    pub fn init(
        allocator: std.mem.Allocator,
        configs: []Log.Config,
    ) !Data {
        // TODO: Allow to log a line the with multiple config
        var result: Data = undefined;
        result.lines = try allocator.alloc(Data.Line, configs.len);
        errdefer result.deinit(allocator);
        for (configs, 0..) |config, idx| {
            result.lines[idx] = try Data.Line.init(
                allocator,
                config,
            );
        }
        result.timestamp = 0;
        return result;
    }

    /// Release allocated memory.
    pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
        for (self.lines) |*line| {
            line.deinit(allocator);
        }
        allocator.free(self.lines);
        self.timestamp = 0;
    }

    /// Reset the logged value of axes and drivers
    pub fn reset(self: *Data) void {
        for (self.lines) |*line| {
            @memset(line.axes, std.mem.zeroInit(
                Data.Line.Axis,
                .{},
            ));
            @memset(line.drivers, std.mem.zeroInit(
                Data.Line.Driver,
                .{},
            ));
        }
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
        net: *Network,
    ) !void {
        self.timestamp = @intCast(std.time.timestamp());
        for (configs, self.lines) |config, *line| {
            {
                const msg = try api_helper.request.info.system.encode(
                    allocator,
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
                defer allocator.free(msg);
                try net.send(msg);
            }
            const msg = try net.receive(allocator);
            defer allocator.free(msg);
            const response = try api_helper.response.info.system.decode(
                allocator,
                msg,
            );
            try api_helper.response.info.system.toLog(
                response,
                line,
            );
        }
    }
};

/// Assign the allocator and allocate line configurations. Call deinit to release
/// the memory
pub fn init(
    /// Allocator for allocating the memory for logging data and configuration
    allocator: std.mem.Allocator,
    /// Number of lines from mcl configuration
    line: client.Line.Id,
    endpoint: Network.Endpoint,
) !Log {
    return .{
        .allocator = allocator,
        .configs = try allocator.alloc(Config, line),
        // Everything below this comment will be provided when the log starts
        .endpoint = endpoint,
        .path = &.{},
        // Both data and timestamps circular buffer will be initialized once
        // the command to start the logging is provided.
        .data = undefined,
        .timestamps = undefined,
    };
}

pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
    allocator.free(self.configs);
    self.reset(allocator);
}

/// Clear all memory except congfigs, so that user can start logging instantly.
pub fn reset(self: *Log, allocator: std.mem.Allocator) void {
    allocator.free(self.path);
    allocator.free(self.endpoint.ip);
    self.endpoint = .{ .ip = &.{}, .port = 0 };
    self.data.deinit();
    self.timestamps.deinit();
    self.allocator = undefined;
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
                if (std.mem.eql(u8, "id", field.name)) {
                    // Do not make a header for root id
                } else try writer.print(
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
fn write(self: *Log, writer: *std.Io.Writer) !void {
    // Write header for the logging file
    try writer.writeAll("timestamp,");
    const first_data = (self.data.peek() orelse {
        std.log.err("NoLoggedData", .{});
        return;
    })[0];
    for (self.configs) |config| {
        var buf: [64]u8 = undefined;
        if (!config.axis and !config.driver) continue;
        const line = client.lines[config.id - 1];
        if (config.driver) {
            const drivers = first_data.drivers;
            for (drivers) |driver| {
                try writeHeaders(
                    writer,
                    try std.fmt.bufPrint(
                        &buf,
                        "{s}_driver{d}",
                        .{ line.name, driver.id },
                    ),
                    "",
                    Log.Data.Line.Driver,
                );
            }
        }
        if (config.axis) {
            const axes = first_data.axes;
            for (axes) |axis| {
                try writeHeaders(
                    writer,
                    try std.fmt.bufPrint(
                        &buf,
                        "{s}_driver{d}",
                        .{ line.name, axis.id },
                    ),
                    "",
                    Log.Data.Line.Axis,
                );
            }
        }
    }
    // Write the data to the logging file
    while (self.data.readItem()) |lines| {
        try writer.writeByte('\n');
        try writer.print(
            "{d},",
            .{self.timestamps.readItem() orelse
                return error.InvalidLoggingData},
        );
        for (lines) |line| {
            for (line.drivers) |driver| {
                try writeValues(writer, driver);
            }
            for (line.axes) |axis| {
                try writeValues(writer, axis);
            }
        }
    }
}

/// Handler for the whole logging process
pub fn handler(duration: f64) !void {
    defer client.log.deinit(client.log.allocator);
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
    std.log.info("The registers will be logged to {s}", .{client.log.path});
    const log_file = try std.fs.cwd().createFile(client.log.path, .{});
    defer log_file.close();
    const logging_size = @as(usize, @intFromFloat(logging_size_float));
    var net = try Network.connect(
        client.log.allocator,
        client.log.endpoint,
    );
    defer net.deinit(client.allocator);
    var data = try Data.init(
        client.log.allocator,
        client.log.configs,
    );
    client.log.data = try CircularBufferAlloc([]Data.Line).initCapacity(
        client.log.allocator,
        logging_size,
    );
    // Memory allocation for the circular buffer since the type is a slice.
    // Reducing memory footprints.
    // for (client.log.data.buffer) |*lines| {
    //     for (lines.*, client.log.configs) |line, config| {
    //         line = try Data.Line.init(client.log.allocator, config);
    //     }
    // }
    // defer {
    //     for (client.log.data.buffer) |*lines| {
    //         for (lines.*) |*line| {
    //             line.deinit(client.log.allocator);
    //         }
    //     }
    // }
    client.log.timestamps = try CircularBufferAlloc(u64).initCapacity(
        client.log.allocator,
        logging_size,
    );
    // TODO: This approach make checkError cannot be used by other thread.
    //       Find a better approach.
    // Remove any previous detected error.
    command.checkError() catch {};
    defer std.log.debug("Logging stopped", .{});
    const log_time_start: u64 = @intCast(std.time.microTimestamp());
    var timer = try std.time.Timer.start();
    while (true) {
        // Check if there is an error after the log started, including the
        // command cancellation.
        command.checkError() catch |e| {
            std.log.debug("{t}", .{e});
            std.log.debug("{?f}", .{@errorReturnTrace()});
            break;
        };
        while (timer.read() < mcl_update * std.time.ns_per_ms) {}
        timer.reset();
        data.get(client.log.allocator, client.log.configs, &net) catch |e| {
            std.log.debug("{t}", .{e});
            std.log.debug("{?f}", .{@errorReturnTrace()});
            // NOTE: Should the main thread be notified to stop any running
            //       command? Example use case: When execute a file, if the
            //       logging failed, it is hard to notice that the logging
            //       is finished while keep executing commands.
            break;
        };
        defer data.reset();
        data.timestamp = data.timestamp - log_time_start;
        client.log.data.writeItemOverwrite(data.lines);
        client.log.timestamps.writeItemOverwrite(data.timestamp);
    }
    var log_writer = log_file.writer(&.{});
    try client.log.write(&log_writer.interface);
    try log_writer.interface.flush();
    std.log.info("Logging data is saved successfully.", .{});
}
