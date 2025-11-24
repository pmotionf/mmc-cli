const log = @This();

const std = @import("std");
const api = @import("mmc-api");
const zignet = @import("zignet");

const client = @import("../mmc_client.zig");
const command = @import("../../command.zig");

pub const Range = struct { start: u32 = 0, end: u32 = 0 };
/// Logging configuration of mmc-client. Shall be initialized once the client
/// is connected to server. Must be deinitialized if the client is disconnected.
pub const Config = struct {
    /// Stores the log configuration of every lines that is passed by the track
    /// config, even for the line that is not going to be logged.
    lines: []Line,

    /// Line configuration of mmc logging.
    const Line = struct {
        /// Line ID, similar to track configuration.
        id: client.Line.Id,
        /// Tracking which drivers to be logged.
        drivers: []bool,
        /// Tracking which axes to be logged.
        axes: []bool,

        pub fn isInitialized(line: Line) bool {
            for (line.axes) |axis|
                if (axis) return true;
            for (line.drivers) |driver|
                if (driver) return true;
            return false;
        }
    };

    pub fn init(allocator: std.mem.Allocator, lines: []client.Line) !Config {
        var result: Config = undefined;
        result.lines = try allocator.alloc(Line, lines.len);
        errdefer result.deinit(allocator);
        for (result.lines, lines) |*config_line, track_line| {
            config_line.id = track_line.id;
            config_line.axes = try allocator.alloc(bool, track_line.axes);
            for (config_line.axes) |*axis| axis.* = false;
            config_line.drivers = try allocator.alloc(bool, track_line.drivers);
            for (config_line.drivers) |*driver| driver.* = false;
        }
        return result;
    }

    pub fn deinit(config: Config, allocator: std.mem.Allocator) void {
        for (config.lines) |line| {
            allocator.free(line.axes);
            allocator.free(line.drivers);
        }
        allocator.free(config.lines);
    }

    /// Check whether there is at least one axis or one driver is set to be
    /// logged.
    pub fn isInitialized(config: Config) bool {
        for (config.lines) |line| {
            if (line.isInitialized()) return true;
        }
        return false;
    }

    pub fn status(self: Config) !void {
        std.log.info("Logging configuration:", .{});
        var stdout_buf: [4096]u8 = undefined;
        var stdout = std.fs.File.stdout().writer(&stdout_buf);
        defer stdout.interface.flush() catch {};
        for (self.lines) |line| {
            if (line.isInitialized() == false) continue;
            try stdout.interface
                .print("Line {s}: ", .{client.lines[line.id - 1].name});
            var axis_range: Range = .{};
            var driver_range: Range = .{};
            var first_axis_entry = true;
            var first_driver_entry = true;
            try stdout.interface.print("axis: [", .{});
            for (line.axes, 1..) |axis, axis_id| {
                if (axis == false) {
                    if (axis_range.start == 0)
                        continue
                    else if (axis_range.start == axis_range.end) {
                        if (first_axis_entry) first_axis_entry = false else {
                            try stdout.interface.print(",", .{});
                        }
                        try stdout.interface.print("{d}", .{axis_range.start});
                    } else {
                        if (first_axis_entry) first_axis_entry = false else {
                            try stdout.interface.print(",", .{});
                        }
                        try stdout.interface.print(
                            "{d}-{d}",
                            .{ axis_range.start, axis_range.end },
                        );
                    }
                    axis_range = .{};
                    continue;
                }
                if (axis_range.start == 0)
                    axis_range =
                        .{ .start = @intCast(axis_id), .end = @intCast(axis_id) }
                else
                    axis_range.end = @intCast(axis_id);
            }
            if (axis_range.start == 0) {
                // Do nothing
            } else if (axis_range.start == axis_range.end) {
                if (first_axis_entry) first_axis_entry = false else {
                    try stdout.interface.print(",", .{});
                }
                try stdout.interface.print("{d}", .{axis_range.start});
            } else {
                if (first_axis_entry) first_axis_entry = false else {
                    try stdout.interface.print(",", .{});
                }
                try stdout.interface.print(
                    "{d}-{d}",
                    .{ axis_range.start, axis_range.end },
                );
            }
            try stdout.interface.print("], driver: [", .{});
            for (line.drivers, 1..) |driver, driver_id| {
                if (driver == false) {
                    if (driver_range.start == 0)
                        continue
                    else if (driver_range.start == driver_range.end) {
                        if (first_driver_entry) first_driver_entry = false else {
                            try stdout.interface.print(",", .{});
                        }
                        try stdout.interface.print("{d}", .{driver_range.start});
                    } else {
                        if (first_driver_entry) first_driver_entry = false else {
                            try stdout.interface.print(",", .{});
                        }
                        try stdout.interface.print(
                            "{d}-{d}",
                            .{ driver_range.start, driver_range.end },
                        );
                    }
                    driver_range = .{};
                    continue;
                }
                if (driver_range.start == 0)
                    driver_range =
                        .{ .start = @intCast(driver_id), .end = @intCast(driver_id) }
                else
                    driver_range.end = @intCast(driver_id);
            }
            if (driver_range.start == 0) {
                // Do nothing
            } else if (driver_range.start == driver_range.end) {
                if (first_driver_entry) first_driver_entry = false else {
                    try stdout.interface.print(",", .{});
                }
                try stdout.interface.print("{d}", .{driver_range.start});
            } else {
                if (first_driver_entry) first_driver_entry = false else {
                    try stdout.interface.print(",", .{});
                }
                try stdout.interface.print(
                    "{d}-{d}",
                    .{ driver_range.start, driver_range.end },
                );
            }
            try stdout.interface.print("]\n", .{});
        }
    }
};

/// Logging data stream for one iteration of logging process. Stream have to be
/// initialized when the log runner is executed and deinitialized upon exit.
/// The stream shall be passed to ring buffer and reset on every iteration of
/// logging process. This method prevents dynamic allocation on every iteration.
const Stream = struct {
    /// Store all logging data for every iteration.
    data: []Stream.Data,
    /// Locate the head index of the data.
    head: usize,
    /// Valid sequential data from the head.
    count: usize,
    /// Optimized logging configuration for requesting data.
    config: Stream.Config,
    socket: zignet.Socket,
    reader: zignet.Socket.Reader,
    writer: zignet.Socket.Writer,

    /// Store one iteration of data.
    const Data = struct {
        /// Timestamp in second.
        timestamp: f64 = 0,
        /// Store logging data of every line.
        lines: []Stream.Data.Line,

        /// Line data structure of mmc logging.
        const Line = struct {
            id: u32,
            /// Store logging data of every axis on a line.
            axes: []Axis,
            /// Store logging data of every driver on a line.
            drivers: []Driver,

            /// Axis data structure of mmc logging.
            const Axis = struct {
                id: u32,
                hall: struct { back: bool, front: bool },
                motor_active: bool,
                waiting_pull: bool,
                waiting_push: bool,
                carrier: Carrier,
                err: Error,
                pub const Carrier = struct {
                    id: u10,
                    position: f32,
                    state: api.protobuf.mmc.info.Response.Track.Carrier.State.State,
                    cas: struct { enabled: bool, triggered: bool },
                };
                pub const Error = struct {
                    overcurrent: bool,
                };
            };

            /// Driver data structure of mmc logging.
            pub const Driver = struct {
                id: u32,
                connected: bool,
                busy: bool,
                motor_disabled: bool,
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
        };
    };

    /// Request info track configuration. This config optimizes the log config,
    /// avoiding requesting track info for every lines, and every axes on each
    /// line.
    const Config = struct {
        lines: std.ArrayList(Stream.Config.Line),

        const Line = struct {
            /// Line ID to be requested.
            id: u32,
            /// The axis range of a line to be requested.
            axis_range: Range,
            /// Request axis state and error if set. Require at least one log
            /// config axis to be set.
            axis: bool,
            /// Request driver state and error if set. Require at least one log
            /// config axis to be set.
            driver: bool,
        };
    };

    fn init(
        allocator: std.mem.Allocator,
        logging_size: usize,
        config: log.Config,
        lines: []client.Line,
        endpoint: zignet.Endpoint,
    ) !Stream {
        var stream: Stream = undefined;
        stream.data = try allocator.alloc(Stream.Data, logging_size);
        errdefer {
            for (stream.data) |data| {
                if (data.lines.len == 0) continue;
                for (data.lines) |stream_line| {
                    if (stream_line.axes.len >= 0)
                        allocator.free(stream_line.axes);
                    if (stream_line.drivers.len >= 0)
                        allocator.free(stream_line.drivers);
                }
                allocator.free(data.lines);
            }
            allocator.free(stream.data);
        }
        for (stream.data) |*data| {
            data.lines = try allocator.alloc(Stream.Data.Line, lines.len);
            for (data.lines, lines) |*stream_line, track_line| {
                stream_line.axes =
                    try allocator.alloc(Stream.Data.Line.Axis, track_line.axes);
                stream_line.drivers =
                    try allocator.alloc(
                        Stream.Data.Line.Driver,
                        track_line.drivers,
                    );
                for (stream_line.axes) |*axis| axis.* =
                    std.mem.zeroInit(Stream.Data.Line.Axis, .{});
                for (stream_line.drivers) |*driver| driver.* =
                    std.mem.zeroInit(Stream.Data.Line.Driver, .{});
            }
            data.timestamp = 0;
        }
        stream.head = 0;
        stream.count = 0;
        stream.socket = try zignet.Socket.connect(
            endpoint,
            &command.checkCommandInterrupt,
        );
        stream.reader = stream.socket.reader(&stream_writer_buf);
        stream.writer = stream.socket.writer(&stream_reader_buf);
        stream.config.lines = .empty;
        errdefer stream.config.lines.deinit(allocator);
        for (config.lines) |line| {
            // Check if there is any log configured for the line
            if (std.mem.allEqual(bool, line.axes, false) and
                std.mem.allEqual(bool, line.drivers, false)) continue;
            // NOTE: Since the client does not know how many axes are there
            // in one driver, the log client need to request the driver
            // information first to define the axis range.
            var axis_range: Range = .{};
            var log_axis = false;
            var log_driver = false;
            // Requesting axis info with driver filter. Filling axis_range.
            for (line.drivers, 1..) |driver, id| {
                if (driver == false) continue;
                log_driver = true;
                const request: api.protobuf.mmc.Request = .{
                    .body = .{
                        .info = .{
                            .body = .{
                                .track = .{
                                    .line = line.id,
                                    .info_axis_state = true,
                                    .filter = .{
                                        .drivers = .{
                                            .start = @intCast(id),
                                            .end = @intCast(id),
                                        },
                                    },
                                },
                            },
                        },
                    },
                };
                try client.removeIgnoredMessage(stream.socket);
                try stream.socket.waitToWrite();
                // Send message
                try request.encode(&stream.writer.interface, allocator);
                try stream.writer.interface.flush();
                // Receive message
                try stream.socket.waitToRead();
                var decoded: api.protobuf.mmc.Response = try .decode(
                    &stream.reader.interface,
                    allocator,
                );
                defer decoded.deinit(allocator);
                const track = switch (decoded.body orelse
                    return error.InvalidResponse) {
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .track => |track_resp| track_resp,
                        .request_error => |req_err| {
                            return client.error_response
                                .throwInfoError(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    .request_error => |req_err| {
                        return client.error_response.throwMmcError(req_err);
                    },
                    else => return error.InvalidResponse,
                };
                if (track.line != line.id) return error.InvalidResponse;
                for (track.axis_state.items) |axis| {
                    // Check if axis range is still default
                    if (axis_range.start == 0 and axis_range.end == 0) {
                        axis_range = .{ .start = axis.id, .end = axis.id };
                    }
                    // Check if the current axis is less than the start of
                    // axis range
                    else if (axis.id < axis_range.start) {
                        axis_range.start = axis.id;
                    }
                    // Check if the current axis is greater than the end of
                    // axis range
                    else if (axis.id > axis_range.end) {
                        axis_range.end = axis.id;
                    }
                }
            }
            // Filling axis_range.
            for (line.axes, 1..) |axis, id| {
                if (axis == false) continue;
                log_axis = true;
                // Check if axis range is still default
                if (axis_range.start == 0 and axis_range.end == 0) {
                    axis_range =
                        .{ .start = @intCast(id), .end = @intCast(id) };
                }
                // Check if the current axis is less than the start of
                // axis range
                else if (id < axis_range.start) {
                    axis_range.start = @intCast(id);
                }
                // Check if the current axis is greater than the end of
                // axis range
                else if (id > axis_range.end) {
                    axis_range.end = @intCast(id);
                }
            }
            try stream.config.lines.append(allocator, .{
                .id = line.id,
                .axis_range = axis_range,
                .axis = log_axis,
                .driver = log_driver,
            });
        }
        return stream;
    }

    fn deinit(stream: *Stream, allocator: std.mem.Allocator) void {
        for (stream.data) |*data| {
            for (data.lines) |*line| {
                allocator.free(line.axes);
                allocator.free(line.drivers);
            }
            allocator.free(data.lines);
        }
        allocator.free(stream.data);
        stream.config.lines.deinit(allocator);
        stream.socket.close();
    }

    /// Get the data from the server based on the stream config.
    fn get(
        stream: *Stream,
        allocator: std.mem.Allocator,
        timestamp: f64,
    ) !void {
        const tail = (stream.head + stream.count) % stream.data.len;
        if (stream.count == stream.data.len)
            stream.head = (stream.head + 1) % stream.data.len
        else
            stream.count += 1;
        var data = &stream.data[tail];
        errdefer {
            // If getting data is failing on this occasion, remove the data
            // so that it will not be written to a file.
            stream.count -= 1;
        }
        data.timestamp = timestamp;
        for (stream.config.lines.items) |line| {
            // Get the data from the server
            const request: api.protobuf.mmc.Request = .{
                .body = .{
                    .info = .{
                        .body = .{
                            .track = .{
                                .line = line.id,
                                .info_axis_errors = line.axis,
                                .info_axis_state = line.axis,
                                .info_carrier_state = line.axis,
                                .info_driver_errors = line.driver,
                                .info_driver_state = line.driver,
                                .filter = .{
                                    .axes = .{
                                        .start = line.axis_range.start,
                                        .end = line.axis_range.end,
                                    },
                                },
                            },
                        },
                    },
                },
            };
            try client.removeIgnoredMessage(stream.socket);
            try stream.socket.waitToWrite();
            // Send message
            try request.encode(&stream.writer.interface, allocator);
            try stream.writer.interface.flush();
            // Receive message
            try stream.socket.waitToRead();
            var decoded: api.protobuf.mmc.Response = try .decode(
                &stream.reader.interface,
                allocator,
            );
            defer decoded.deinit(allocator);
            const track = switch (decoded.body orelse
                return error.InvalidResponse) {
                .info => |info_resp| switch (info_resp.body orelse
                    return error.InvalidResponse) {
                    .track => |track_resp| track_resp,
                    .request_error => |req_err| {
                        return client.error_response
                            .throwInfoError(req_err);
                    },
                    else => return error.InvalidResponse,
                },
                .request_error => |req_err| {
                    return client.error_response.throwMmcError(req_err);
                },
                else => return error.InvalidResponse,
            };
            if (track.line != line.id) return error.InvalidResponse;
            // Store the data to the buffer
            // TODO: Optimize the storing to store directly to circular
            // buffer instead of making a copy first before calling
            // `writeItemOverwrite()`
            // std.log.debug("{}", .{stream.data[tail].lines[0]});
            data.lines[track.line - 1].id = track.line;
            for (
                track.axis_state.items,
                track.axis_errors.items,
            ) |axis_info, axis_err| {
                data.lines[line.id - 1].axes[axis_info.id - 1] = .{
                    .id = axis_info.id,
                    .hall = .{
                        .front = axis_info.hall_alarm_front,
                        .back = axis_info.hall_alarm_back,
                    },
                    .motor_active = axis_info.motor_active,
                    .waiting_pull = axis_info.waiting_pull,
                    .waiting_push = axis_info.waiting_push,
                    .err = .{
                        .overcurrent = axis_err.overcurrent,
                    },
                    .carrier = std.mem.zeroInit(
                        Stream.Data.Line.Axis.Carrier,
                        .{},
                    ),
                };
            }
            for (track.carrier_state.items) |carrier| {
                data.lines[line.id - 1]
                    .axes[carrier.axis_main - 1].carrier = .{
                    .id = @intCast(carrier.id),
                    .position = carrier.position,
                    .state = carrier.state,
                    .cas = .{
                        .enabled = !carrier.cas_disabled,
                        .triggered = carrier.cas_triggered,
                    },
                };
                if (carrier.axis_auxiliary) |aux|
                    data.lines[line.id - 1].axes[aux - 1].carrier = .{
                        .id = @intCast(carrier.id),
                        .position = carrier.position,
                        .state = carrier.state,
                        .cas = .{
                            .enabled = !carrier.cas_disabled,
                            .triggered = carrier.cas_triggered,
                        },
                    };
            }
            for (
                track.driver_state.items,
                track.driver_errors.items,
            ) |driver_info, driver_err| {
                data.lines[line.id - 1].drivers[driver_info.id - 1] = .{
                    .id = driver_info.id,
                    .connected = driver_info.connected,
                    .busy = driver_info.busy,
                    .motor_disabled = driver_info.motor_disabled,
                    .stopped = driver_info.stopped,
                    .paused = driver_info.paused,
                    .err = .{
                        .control_loop_max_time_exceeded = driver_err
                            .control_loop_time_exceeded,
                        .inverter_overheat = driver_err.inverter_overheat,
                        .power = .{
                            .overvoltage = driver_err.overvoltage,
                            .undervoltage = driver_err.undervoltage,
                        },
                        .comm = .{
                            .from_prev = driver_err.comm_error_prev,
                            .from_next = driver_err.comm_error_next,
                        },
                    },
                };
            }
        }
    }
};

/// The mmc-client must check `executing` flag before disconnecting the client
/// to ensure the log is saved first.
pub var executing = std.atomic.Value(bool).init(false);
/// Stop the logging process from other thread and save the log data to log
/// file.
pub var stop = std.atomic.Value(bool).init(false);
/// Stop the logging and do not save the log data to a file.
pub var cancel = std.atomic.Value(bool).init(false);

var stream_writer_buf: [4096]u8 = undefined;
var stream_reader_buf: [4096]u8 = undefined;
var file_reader_buf: [4096]u8 = undefined;
var file_writer_buf: [4096]u8 = undefined;

pub fn runner(duration: f64, file_path: []const u8) !void {
    defer client.allocator.free(file_path);
    // Validation steps
    if (client.log_config.isInitialized() == false)
        return error.LoggingNotConfigured;
    // Assumption: The register is updated every 3 ms.
    const update_rate = 3;
    const logging_size_float =
        duration * @as(f64, @floatFromInt(std.time.ms_per_s)) / update_rate;
    if (std.math.isNan(logging_size_float) or
        std.math.isInf(logging_size_float) or
        !std.math.isFinite(logging_size_float) or
        logging_size_float <= 0) return error.InvalidDuration;
    executing.store(true, .monotonic);
    defer executing.store(false, .monotonic);
    // Stream setup.
    if (client.sock == null) return error.SocketNotConnected;
    var stream: Stream = try .init(
        client.allocator,
        @as(usize, @intFromFloat(logging_size_float)),
        client.log_config,
        client.lines,
        client.endpoint orelse return error.MissingEndpoint,
    );
    defer stream.deinit(client.allocator);
    // Logging file setup.
    const log_file = try std.fs.cwd().createFile(file_path, .{});
    defer {
        log_file.close();
        if (cancel.load(.monotonic))
            std.fs.cwd().deleteFile(file_path) catch {};
    }
    std.log.info("The registers will be logged to {s}.", .{file_path});
    const log_time_start = std.time.microTimestamp();
    var timer = try std.time.Timer.start();
    var timestamp: f64 = 0;
    // Reset the stop and cancel bit before starting to log.
    stop.store(false, .monotonic);
    cancel.store(false, .monotonic);
    while (stop.load(.monotonic) == false) {
        if (cancel.load(.monotonic)) {
            std.log.info("Logging is cancelled.", .{});
            return;
        }
        timestamp = @as(
            f64,
            @floatFromInt(std.time.microTimestamp() - log_time_start),
        ) / std.time.us_per_s;
        stream.get(client.allocator, timestamp) catch |e| {
            std.log.err("{t}", .{e});
            std.log.debug("{?f}", .{@errorReturnTrace()});
            break;
        };
        // Wait to match the update rate.
        while (timer.read() < update_rate * std.time.ns_per_ms) {}
        timer.reset();
    }
    std.log.info("Logging is stopped.", .{});
    stop.store(false, .monotonic);
    var log_writer = log_file.writer(&.{});
    // Write the headers of the data to the logging file.
    try log_writer.interface.print("timestamp,", .{});
    for (client.log_config.lines) |line_config| {
        var buf: [64]u8 = undefined;
        for (line_config.drivers, 1..) |log_driver, driver_id| {
            if (log_driver == false) continue;
            try writeHeaders(
                &log_writer.interface,
                try std.fmt.bufPrint(
                    &buf,
                    "{s}_driver{d}",
                    .{ client.lines[line_config.id - 1].name, driver_id },
                ),
                "",
                Stream.Data.Line.Driver,
            );
        }
        for (line_config.axes, 1..) |log_axis, axis_id| {
            if (log_axis == false) continue;
            try writeHeaders(
                &log_writer.interface,
                try std.fmt.bufPrint(
                    &buf,
                    "{s}_axis{d}",
                    .{ client.lines[line_config.id - 1].name, axis_id },
                ),
                "",
                Stream.Data.Line.Axis,
            );
        }
    }
    // Write the data to the logging file.
    while (stream.count != 0) {
        const log_data = stream.data[stream.head];
        stream.head = (stream.head + 1) % stream.data.len;
        stream.count -= 1;
        if (timestamp - log_data.timestamp > duration) continue;
        try log_writer.interface.writeByte('\n');
        try log_writer.interface.print("{},", .{log_data.timestamp});
        for (client.log_config.lines) |line_config| {
            const line_data = log_data.lines[line_config.id - 1];
            for (
                line_data.drivers,
                line_config.drivers,
            ) |driver_data, log_driver| {
                if (log_driver == false) continue;
                try writeValues(&log_writer.interface, driver_data, "driver");
            }
            for (line_data.axes, line_config.axes) |axis_data, log_axis| {
                if (log_axis == false) continue;
                try writeValues(&log_writer.interface, axis_data, "axis");
            }
        }
    }
    std.log.info("Logging data is saved successfully.", .{});
}

fn writeHeaders(
    w: *std.Io.Writer,
    prefix: []const u8,
    comptime parent: []const u8,
    comptime Parent: type,
) !void {
    const ti = @typeInfo(Parent).@"struct";
    inline for (ti.fields) |field| {
        if (@typeInfo(field.type) == .@"struct") {
            if (parent.len == 0)
                try writeHeaders(
                    w,
                    prefix,
                    field.name,
                    field.type,
                )
            else
                try writeHeaders(
                    w,
                    prefix,
                    parent ++ "." ++ field.name,
                    field.type,
                );
        } else {
            if (parent.len == 0) {
                if (std.mem.eql(u8, "id", field.name)) {
                    // Do nothing
                } else try w.print(
                    "{s}_{s},",
                    .{ prefix, field.name },
                );
            } else try w.print(
                "{s}_{s},",
                .{ prefix, parent ++ "." ++ field.name },
            );
        }
    }
}

fn writeValues(
    w: *std.Io.Writer,
    parent: anytype,
    parent_str: []const u8,
) !void {
    const parent_ti = @typeInfo(@TypeOf(parent)).@"struct";
    inline for (parent_ti.fields) |field| {
        if (@typeInfo(field.type) == .@"struct")
            try writeValues(w, @field(parent, field.name), field.name)
        else {
            if (@typeInfo(field.type) == .optional) {
                if (@field(parent, field.name)) |value|
                    try w.print("{},", .{value})
                else
                    try w.write("None,");
            } else if (@typeInfo(field.type) == .@"enum") {
                try w.print(
                    "{t}({d}),",
                    .{ @field(parent, field.name), @intFromEnum(
                        @field(parent, field.name),
                    ) },
                );
            } else {
                if (!std.mem.eql(u8, parent_str, "carrier") and
                    std.mem.eql(u8, field.name, "id"))
                {
                    // Do nothing on id field unless the parent is carrier.
                } else try w.print(
                    "{},",
                    .{@field(parent, field.name)},
                );
            }
        }
    }
}
