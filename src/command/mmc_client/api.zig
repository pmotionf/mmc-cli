// This file purpose is an interface for parsing the response and creating a
// request to the server.
const std = @import("std");
const Line = @import("Line.zig");
const Log = @import("Log.zig");

pub const api = @import("mmc-api");

pub const response = struct {
    pub const core = struct {
        pub const track_config = struct {
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.core_msg.Response.TrackConfig {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                errdefer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .track_config => |config| return config,
                        .request_error => |req_err| {
                            return core.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        pub const api_version = struct {
            /// Decode the response.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.core_msg.Response.SemanticVersion {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                defer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .api_version => |api_ver| return api_ver,
                        .request_error => |req_err| {
                            return core.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        pub const server = struct {
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.core_msg.Response.Server {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                errdefer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .server => |server_resp| return server_resp,
                        .request_error => |req_err| {
                            return core.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        fn error_handler(err: api.core_msg.Request.Error) anyerror {
            return switch (err) {
                .CORE_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .CORE_REQUEST_ERROR_REQUEST_UNKNOWN => error.RequestUnknown,
                _ => unreachable,
            };
        }
    };
    pub const command = struct {
        pub const id = struct {
            /// Decode the response.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !u32 {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                defer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        .id => |comm_id| {
                            // ID is guaranteed to not be 0
                            if (comm_id == 0) return error.InvalidIdResponse;
                            return comm_id;
                        },
                        .request_error => |req_err| {
                            return command.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        pub const cleared_id = struct {
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !u32 {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                defer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        .cleared_id => |_id| return _id,
                        .request_error => |req_err| {
                            return command.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        fn error_handler(err: api.command_msg.Request.Error) anyerror {
            return switch (err) {
                .COMMAND_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .COMMAND_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .COMMAND_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .COMMAND_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
                .COMMAND_REQUEST_ERROR_INVALID_ACCELERATION => error.InvalidAcceleration,
                .COMMAND_REQUEST_ERROR_INVALID_VELOCITY => error.InvalidSpeed,
                .COMMAND_REQUEST_ERROR_INVALID_DIRECTION => error.InvalidDirection,
                .COMMAND_REQUEST_ERROR_INVALID_LOCATION => error.InvalidLocation,
                .COMMAND_REQUEST_ERROR_INVALID_DISTANCE => error.InvalidDistance,
                .COMMAND_REQUEST_ERROR_INVALID_CARRIER => error.InvalidCarrier,
                .COMMAND_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                .COMMAND_REQUEST_ERROR_COMMAND_NOT_FOUND => error.CommandNotFound,
                .COMMAND_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .COMMAND_REQUEST_ERROR_OUT_OF_MEMORY => error.ServerRunningOutOfMemory,
                .COMMAND_REQUEST_ERROR_MAXIMUM_AUTO_INITIALIZE_EXCEEDED => error.MaximumAutoInitializeExceeded,
                _ => unreachable,
            };
        }
    };
    pub const info = struct {
        pub const command = struct {
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.info_msg.Response.Commands {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                errdefer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .command => |commands_resp| {
                            return commands_resp;
                        },
                        .request_error => |req_err| {
                            return info.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        pub const track = struct {
            pub const axis = struct {
                pub const state = struct {
                    /// Print all axis information into the screen
                    pub fn print(
                        axis_info: api.info_msg.Response.Track.Axis.State,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Axis state",
                            axis_info,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                };
                pub const err = struct {
                    /// Print all axis information into the screen
                    pub fn print(
                        axis_err: api.info_msg.Response.Track.Axis.Error,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Axis error",
                            axis_err,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                    /// Print only active error bit
                    pub fn printActive(
                        axis_err: api.info_msg.Response.Track.Axis.Error,
                        writer: *std.Io.Writer,
                    ) !void {
                        const ti = @typeInfo(@TypeOf(axis_err)).@"struct";
                        inline for (ti.fields) |field| {
                            switch (@typeInfo(field.type)) {
                                .optional => {
                                    const child = @field(
                                        axis_err,
                                        field.name,
                                    ).?;
                                    const inner_ti =
                                        @typeInfo(@TypeOf(child)).@"struct";
                                    inline for (inner_ti.fields) |inner| {
                                        if (@field(child, inner.name))
                                            try writer.print(
                                                "{s}.{s} on axis {d}\n",
                                                .{
                                                    field.name,
                                                    inner.name,
                                                    axis_err.id,
                                                },
                                            );
                                    }
                                },
                                .bool => {
                                    if (@field(axis_err, field.name))
                                        try writer.print(
                                            "{s} on axis {d}\n",
                                            .{ field.name, axis_err.id },
                                        );
                                },
                                else => {},
                            }
                        }
                        try writer.flush();
                    }
                };
            };
            pub const driver = struct {
                pub const state = struct {
                    /// Print all axis information into the screen
                    pub fn print(
                        driver_info: api.info_msg.Response.Track.Driver.State,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Driver state",
                            driver_info,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                };
                pub const err = struct {
                    /// Print all axis information into the screen
                    pub fn print(
                        driver_err: api.info_msg.Response.Track.Driver.Error,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Driver error",
                            driver_err,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                    /// Print only active error bit
                    pub fn printActive(
                        driver_err: api.info_msg.Response.Track.Driver.Error,
                        writer: *std.Io.Writer,
                    ) !void {
                        const ti = @typeInfo(@TypeOf(driver_err)).@"struct";
                        inline for (ti.fields) |field| {
                            switch (@typeInfo(field.type)) {
                                .optional => {
                                    const child = @field(
                                        driver_err,
                                        field.name,
                                    ).?;
                                    const inner_ti =
                                        @typeInfo(@TypeOf(child)).@"struct";
                                    inline for (inner_ti.fields) |inner| {
                                        if (@field(child, inner.name))
                                            try writer.print(
                                                "{s}.{s} on driver {d}\n",
                                                .{
                                                    field.name,
                                                    inner.name,
                                                    driver_err.id,
                                                },
                                            );
                                    }
                                },
                                .bool => {
                                    if (@field(driver_err, field.name))
                                        try writer.print(
                                            "{s} on axis {d}\n",
                                            .{ field.name, driver_err.id },
                                        );
                                },
                                else => {},
                            }
                        }
                        try writer.flush();
                    }
                };
            };
            pub const carrier = struct {
                /// Print all axis information into the screen
                pub fn print(
                    carrier_info: api.info_msg.Response.Track.Carrier.State,
                    writer: *std.Io.Writer,
                ) !void {
                    _ = try nestedWrite(
                        "Carrier",
                        carrier_info,
                        0,
                        writer,
                    );
                    try writer.flush();
                }
            };
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.info_msg.Response.Track {
                var decoded = try api.mmc_msg.Response.decode(
                    reader,
                    allocator,
                );
                errdefer decoded.deinit(allocator);
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .track => |system_resp| return system_resp,
                        .request_error => |req_err| {
                            return info.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }

            /// Parse track response to fit the logging data
            pub fn toLog(
                system_resp: api.info_msg.Response.Track,
                result: *Log.Data,
            ) !void {
                const axis_infos = system_resp.axis_infos;
                const axis_errors = system_resp.axis_errors;
                const driver_infos = system_resp.driver_infos;
                const driver_errors = system_resp.driver_errors;
                const carriers = system_resp.carrier_state;
                // Parse axes information response
                for (
                    axis_infos.items,
                    axis_errors.items,
                ) |axis_info, axis_err| {
                    if (axis_info.id != axis_err.id) return error.InvalidResponse;
                    result.axes[axis_info.id - 1] = .{
                        .id = @intCast(axis_info.id),
                        .hall = .{
                            .front = axis_info.hall_alarm.?.front,
                            .back = axis_info.hall_alarm.?.back,
                        },
                        .motor_active = axis_info.motor_active,
                        .pulling = axis_info.waiting_pull,
                        .pushing = axis_info.waiting_push,
                        .err = .{
                            .overcurrent = axis_err.overcurrent,
                        },
                        .carrier = std.mem.zeroInit(
                            Log.Data.Line.Axis.Carrier,
                            .{},
                        ),
                    };
                }
                // Parse carrier information response to axis.carrier
                for (carriers.items) |_carrier| {
                    const _axis = _carrier.axis.?;
                    const ti = @typeInfo(@TypeOf(_axis)).@"struct";
                    inline for (ti.fields) |field| {
                        const axis_idx = if (@typeInfo(field.type) == .optional) b: {
                            if (@field(_axis, field.name)) |id| {
                                break :b id - 1;
                            } else break;
                        } else @field(_axis, field.name) - 1;
                        result.axes[axis_idx].carrier = .{
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
                    result.drivers[driver_info.id] = .{
                        .id = @intCast(driver_info.id),
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
                }
            }
        };

        fn error_handler(err: api.info_msg.Request.Error) anyerror {
            return switch (err) {
                .INFO_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .INFO_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .INFO_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .INFO_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
                .INFO_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                _ => unreachable,
            };
        }
    };

    fn error_handler(err: api.mmc_msg.Request.Error) anyerror {
        return switch (err) {
            .MMC_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
            .MMC_REQUEST_ERROR_INVALID_MESSAGE => error.InvalidMessage,
            _ => unreachable,
        };
    }
};

pub const request = struct {
    pub const core = struct {
        /// Validate payload and encode to protobuf string. Caller shall free
        /// the memory.
        pub fn encode(
            allocator: std.mem.Allocator,
            writer: *std.Io.Writer,
            comptime payload: api.core_msg.Request.Kind,
        ) !void {
            if (payload == .CORE_REQUEST_KIND_UNSPECIFIED)
                @compileError("Kind is unspecified");
            const msg: api.mmc_msg.Request = .{
                .body = .{
                    .core = .{
                        .kind = payload,
                    },
                },
            };
            try msg.encode(writer, allocator);
        }
    };
    pub const command = struct {
        pub const clear_errors = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.ClearErrors,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .clear_errors = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const deinitialize = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Deinitialize,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .deinitialize = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const release = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Release,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .release = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const stop_pull = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.StopPull,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .stop_pull = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const stop_push = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.StopPush,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .stop_push = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const auto_initialize = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.AutoInitialize,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .auto_initialize = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const move = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Move,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .move = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const push = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Push,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .push = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const pull = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Pull,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .pull = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const initialize = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Initialize,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .initialize = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const calibrate = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.Calibrate,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .calibrate = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const set_zero = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.SetZero,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .set_zero = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const clear_commands = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.ClearCommand,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{ .clear_command = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
    };
    pub const info = struct {
        pub const command = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.info_msg.Request.Command,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .info = .{
                            .body = .{ .command = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const track = struct {
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.info_msg.Request.Track,
            ) !void {
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .info = .{
                            .body = .{ .track = payload },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
    };
};

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
