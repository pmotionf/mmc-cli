// This file purpose is an interface for parsing the response and creating a
// request to the server.
const std = @import("std");
const Axis = @import("Axis.zig");
const Driver = @import("Driver.zig");
const Line = @import("Line.zig");
const Log = @import("Log.zig");

pub const api = @import("mmc-api");

// TODO: If client.zig's configuration has been updated, validate all values
//       with the configuration
pub const response = struct {
    pub const core = struct {
        pub const line_config = struct {
            /// Decode and validate the response. Caller shall free the
            /// allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                msg: []const u8,
            ) !api.core_msg.Response.LineConfig {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                errdefer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .line_config => |config| {
                            if (config.lines.items.len > Line.max)
                                return error.InvalidLineConfig;
                            for (config.lines.items) |line| {
                                if (line.axes > std.math.maxInt(Axis.Id.Line))
                                    return error.InvalidAxesResponse;
                                if (line.length) |length| {
                                    if (length.axis == 0 and length.carrier == 0)
                                        return error.InvalidLengthResponse;
                                } else return error.MissingConfiguration;
                                if (line.name.getSlice().len == 0)
                                    return error.MissingConfiguration;
                            }
                            return config;
                        },
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
            /// Decode and validate the response.
            pub fn decode(
                allocator: std.mem.Allocator,
                msg: []const u8,
            ) !api.core_msg.Response.SemanticVersion {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                defer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .api_version => |api_ver| {
                            if (api_ver.major == 0 and api_ver.minor == 0 and
                                api_ver.patch == 0) return error.InvalidVersionResponse;
                            return api_ver;
                        },
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
            /// Decode and validate the response. Caller shall free the
            /// allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                msg: []const u8,
            ) !api.core_msg.Response.Server {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                errdefer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .server => |server_resp| {
                            if (server_resp.version) |version| {
                                if (version.major == 0 and version.minor == 0 and
                                    version.patch == 0) return error.InvalidVersionResponse;
                            } else return error.MissingConfiguration;
                            if (server_resp.name.getSlice().len == 0) return error.InvalidServerName;
                            return server_resp;
                        },
                        .request_error => |req_err| {
                            return core.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        fn error_handler(err: api.core_msg.Response.RequestErrorKind) anyerror {
            return switch (err) {
                .CORE_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .CORE_REQUEST_ERROR_REQUEST_UNKNOWN => error.RequestUnknown,
                _ => unreachable,
            };
        }
    };
    pub const command = struct {
        pub const id = struct {
            /// Decode and validate the response.
            pub fn decode(allocator: std.mem.Allocator, msg: []const u8) !u32 {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                defer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        .command_id => |comm_id| {
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
        pub const operation = struct {
            pub fn decode(allocator: std.mem.Allocator, msg: []const u8) !bool {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                defer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        // TODO: The API shall change to bool
                        .command_operation => |status| {
                            return switch (status) {
                                .COMMAND_STATUS_UNSPECIFIED => return error.InvalidResponse,
                                .COMMAND_STATUS_COMPLETED => return true,
                                _ => unreachable,
                            };
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
        fn error_handler(err: api.command_msg.Response.RequestErrorKind) anyerror {
            return switch (err) {
                .COMMAND_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .COMMAND_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .COMMAND_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .COMMAND_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                .COMMAND_REQUEST_ERROR_CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .COMMAND_REQUEST_ERROR_INVALID_ACCELERATION => error.InvalidAcceleration,
                .COMMAND_REQUEST_ERROR_INVALID_VELOCITY => error.InvalidSpeed,
                .COMMAND_REQUEST_ERROR_OUT_OF_MEMORY => error.ServerRunningOutOfMemory,
                .COMMAND_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                .COMMAND_REQUEST_ERROR_INVALID_DIRECTION => error.InvalidDirection,
                .COMMAND_REQUEST_ERROR_INVALID_LOCATION => error.InvalidLocation,
                .COMMAND_REQUEST_ERROR_INVALID_DISTANCE => error.InvalidDistance,
                .COMMAND_REQUEST_ERROR_INVALID_CARRIER => error.InvalidCarrier,
                .COMMAND_REQUEST_ERROR_COMMAND_PROGRESSING => error.CommandProgressing,
                .COMMAND_REQUEST_ERROR_COMMAND_NOT_FOUND => error.CommandNotFound,
                .COMMAND_REQUEST_ERROR_MAXIMUM_AUTO_INITIALIZE_EXCEEDED => error.MaximumAutoInitializeExceeded,
                .COMMAND_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
                _ => unreachable,
            };
        }
    };
    pub const info = struct {
        pub const commands = struct {
            /// Decode and validate the response. Caller shall free the
            /// allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                msg: []const u8,
            ) !api.info_msg.Response.Commands {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                errdefer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .commands => |commands_resp| {
                            if (commands_resp.commands.items.len == 0) return error.InvalidResponse;
                            for (commands_resp.commands.items) |comm| {
                                if (comm.id == 0 or comm.id > 4096)
                                    return error.InvalidCommandId;
                                if (comm.status == .STATUS_FAILED and
                                    comm.error_response == null)
                                    return error.MissingFailureKind;
                            }
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
        pub const system = struct {
            pub const axis = struct {
                pub const info = struct {
                    pub fn validate(
                        axis_info: api.info_msg.Response.System.Axis.Info,
                    ) !void {
                        if (axis_info.id == 0 or
                            axis_info.id > Axis.max.line)
                            return error.InvalidAxisResponse;
                        if (axis_info.hall_alarm == null)
                            return error.InvalidAxisResponse;
                        if (axis_info.carrier_id > 2048)
                            return error.InvalidAxisResponse;
                    }

                    /// Print all axis information into the screen
                    pub fn print(
                        axis_info: api.info_msg.Response.System.Axis.Info,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Axis info",
                            axis_info,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                };
                pub const err = struct {
                    pub fn validate(
                        axis_err: api.info_msg.Response.System.Axis.Error,
                    ) !void {
                        if (axis_err.id == 0 or
                            axis_err.id > Axis.max.line)
                            return error.InvalidAxisResponse;
                    }
                    /// Print all axis information into the screen
                    pub fn print(
                        axis_err: api.info_msg.Response.System.Axis.Error,
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
                        axis_err: api.info_msg.Response.System.Axis.Error,
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
                pub const info = struct {
                    pub fn validate(
                        driver_info: api.info_msg.Response.System.Driver.Info,
                    ) !void {
                        if (driver_info.id == 0 or
                            driver_info.id > Driver.max)
                            return error.InvalidDriverResponse;
                    }
                    /// Print all axis information into the screen
                    pub fn print(
                        driver_info: api.info_msg.Response.System.Driver.Info,
                        writer: *std.Io.Writer,
                    ) !void {
                        _ = try nestedWrite(
                            "Driver info",
                            driver_info,
                            0,
                            writer,
                        );
                        try writer.flush();
                    }
                };
                pub const err = struct {
                    pub fn validate(
                        driver_err: api.info_msg.Response.System.Driver.Error,
                    ) !void {
                        if (driver_err.id == 0 or
                            driver_err.id > Driver.max)
                            return error.InvalidDriverResponse;
                        if (driver_err.communication_error == null)
                            return error.InvalidDriverResponse;
                        if (driver_err.power_error == null)
                            return error.InvalidDriverResponse;
                    }
                    /// Print all axis information into the screen
                    pub fn print(
                        driver_err: api.info_msg.Response.System.Driver.Error,
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
                        driver_err: api.info_msg.Response.System.Driver.Error,
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
                pub fn validate(
                    carrier_info: api.info_msg.Response.System.Carrier.Info,
                ) !void {
                    if (carrier_info.id == 0 or carrier_info.id > 2048)
                        return error.InvalidCarrierResponse;
                    if (carrier_info.cas == null)
                        return error.InvalidCarrierResponse;
                    if (carrier_info.axis) |_axis| {
                        if (_axis.main == 0 or _axis.main > Axis.max.line)
                            return error.InvalidCarrierResponse;
                        if (_axis.auxiliary) |aux| {
                            if (aux == 0 or aux > Axis.max.line)
                                return error.InvalidCarrierResponse;
                        }
                    } else return error.InvalidCarrierResponse;
                }
                /// Print all axis information into the screen
                pub fn print(
                    carrier_info: api.info_msg.Response.System.Carrier.Info,
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
            /// Decode and validate the response. Caller shall free the
            /// allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                msg: []const u8,
            ) !api.info_msg.Response.System {
                const decoded = try api.mmc_msg.Response.decode(
                    msg,
                    allocator,
                );
                errdefer decoded.deinit();
                switch (decoded.body orelse return error.InvalidResponse) {
                    .request_error => |req_err| {
                        return response.error_handler(req_err);
                    },
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .system => |system_resp| {
                            if (system_resp.line_id == 0 or
                                system_resp.line_id > Line.max)
                                return error.InvalidLineResponse;
                            for (system_resp.axis_errors.items) |axis_err| {
                                try axis.err.validate(axis_err);
                            }
                            for (system_resp.axis_infos.items) |axis_info| {
                                try axis.info.validate(axis_info);
                            }
                            for (system_resp.driver_infos.items) |driver_info| {
                                try driver.info.validate(driver_info);
                            }
                            for (system_resp.driver_errors.items) |driver_err| {
                                try driver.err.validate(driver_err);
                            }
                            for (system_resp.carrier_infos.items) |carrier_info| {
                                try carrier.validate(carrier_info);
                            }
                            return system_resp;
                        },
                        .request_error => |req_err| {
                            return info.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }

            /// Parse system response to fit the logging data
            pub fn toLog(
                system_resp: api.info_msg.Response.System,
                result: *Log.Data.Line,
            ) !void {
                const axis_infos = system_resp.axis_infos;
                const axis_errors = system_resp.axis_errors;
                const driver_infos = system_resp.driver_infos;
                const driver_errors = system_resp.driver_errors;
                const carriers = system_resp.carrier_infos;
                // Validate that response length match the result length
                if (axis_infos.items.len != axis_errors.items.len or
                    axis_infos.items.len != result.axes.len)
                    return error.InvalidResponse;
                if (driver_infos.items.len != driver_errors.items.len or
                    driver_infos.items.len != result.drivers.len)
                    return error.InvalidResponse;
                // Parse axes information response
                var index: usize = 0;
                for (
                    axis_infos.items,
                    axis_errors.items,
                ) |axis_info, axis_err| {
                    if (axis_info.id != axis_err.id) return error.InvalidResponse;
                    result.axes[index] = .{
                        .id = @intCast(axis_info.id),
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
                            Log.Data.Line.Axis.Carrier,
                            .{},
                        ),
                    };
                    index += 1;
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
                // Parse drivers information response
                for (
                    driver_infos.items,
                    driver_errors.items,
                ) |driver_info, driver_err| {
                    result.drivers[index] = .{
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
                    index += 1;
                }
            }
        };
        fn error_handler(err: api.info_msg.Response.RequestErrorKind) anyerror {
            return switch (err) {
                .INFO_REQUEST_ERROR_UNSPECIFIED => error.InvalidResponse,
                .INFO_REQUEST_ERROR_INVALID_LINE => error.InvalidLine,
                .INFO_REQUEST_ERROR_INVALID_AXIS => error.InvalidAxis,
                .INFO_REQUEST_ERROR_INVALID_DRIVER => error.InvalidDriver,
                .INFO_REQUEST_ERROR_CARRIER_NOT_FOUND => error.CarrierNotFound,
                .INFO_REQUEST_ERROR_CC_LINK_DISCONNECTED => error.CCLinkDisconnected,
                .INFO_REQUEST_ERROR_MISSING_PARAMETER => error.MissingParameter,
                .INFO_REQUEST_ERROR_COMMAND_NOT_FOUND => error.CommandNotFound,
                _ => unreachable,
            };
        }
    };

    fn error_handler(err: api.mmc_msg.Response.RequestError) anyerror {
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
            comptime payload: api.core_msg.Request.Kind,
        ) ![]const u8 {
            if (payload == .CORE_REQUEST_KIND_UNSPECIFIED)
                @compileError("Kind is unspecified");
            const msg: api.mmc_msg.Request = .{
                .body = .{
                    .core = .{
                        .kind = payload,
                    },
                },
            };
            return try msg.encode(allocator);
        }
    };
    pub const command = struct {
        pub const clear_errors = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.ClearErrors,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.driver_id) |driver| {
                    if (driver == 0 or driver > Driver.max)
                        return error.InvalidDriver;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .clear_errors = .{
                                    .line_id = payload.line_id,
                                    .driver_id = payload.driver_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const clear_carriers = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.ClearCarriers,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.axis_id) |axis| {
                    if (axis == 0 or axis > Axis.max.line)
                        return error.InvalidAxis;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .clear_carrier_info = .{
                                    .line_id = payload.line_id,
                                    .axis_id = payload.axis_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const release_control = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.ReleaseControl,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.axis_id) |axis| {
                    if (axis == 0 or axis > Axis.max.line)
                        return error.InvalidAxis;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .release_control = .{
                                    .line_id = payload.line_id,
                                    .axis_id = payload.axis_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const stop_pull_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.StopPullCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.axis_id) |axis| {
                    if (axis == 0 or axis > Axis.max.line)
                        return error.InvalidAxis;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .stop_pull_carrier = .{
                                    .line_id = payload.line_id,
                                    .axis_id = payload.axis_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const stop_push_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.StopPushCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.axis_id) |axis| {
                    if (axis == 0 or axis > Axis.max.line)
                        return error.InvalidAxis;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .stop_push_carrier = .{
                                    .line_id = payload.line_id,
                                    .axis_id = payload.axis_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const auto_initialize = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.AutoInitialize,
            ) ![]const u8 {
                for (payload.lines.items) |line| {
                    if (line.line_id == 0 or line.line_id > Line.max)
                        return error.InvalidPayload;
                    if (line.acceleration) |acc| {
                        if (acc == 0 or acc > 196)
                            return error.InvalidAcceleration;
                    } else return error.InvalidPayload;
                    if (line.velocity) |vel| {
                        if (vel == 0 or vel > 30)
                            return error.InvalidVelocity;
                    } else return error.InvalidPayload;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .auto_initialize = .{
                                    .lines = payload.lines,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const move_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.MoveCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.control_kind == .CONTROL_UNSPECIFIED)
                    return error.InvalidControlKind;
                if (payload.target) |target| {
                    switch (target) {
                        .axis => |axis| {
                            if (axis == 0 or axis > Axis.max.line)
                                return error.InvalidAxisTarget;
                        },
                        .distance => |distance| {
                            if (distance == 0) return error.ZeroDistance;
                        },
                        else => {},
                    }
                } else return error.MissingTarget;
                if (payload.velocity == 0 or payload.velocity > 30)
                    return error.InvalidVelocity;
                if (payload.acceleration == 0 or payload.acceleration > 196)
                    return error.InvalidAcceleration;
                if (payload.carrier_id == 0 or payload.carrier_id > 2048)
                    return error.InvalidCarrier;
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .move_carrier = .{
                                    .line_id = payload.line_id,
                                    .acceleration = payload.acceleration,
                                    .velocity = payload.velocity,
                                    .carrier_id = payload.carrier_id,
                                    .control_kind = payload.control_kind,
                                    .disable_cas = payload.disable_cas,
                                    .target = switch (payload.target.?) {
                                        .axis => |axis| .{
                                            .axis = axis,
                                        },
                                        .location => |loc| .{
                                            .location = loc,
                                        },
                                        .distance => |dist| .{
                                            .distance = dist,
                                        },
                                    },
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const push_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.PushCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.direction == .DIRECTION_UNSPECIFIED)
                    return error.MissingDirection;
                if (payload.velocity == 0 or payload.velocity > 30)
                    return error.InvalidVelocity;
                if (payload.acceleration == 0 or payload.acceleration > 196)
                    return error.InvalidAcceleration;
                if (payload.carrier_id == 0 or payload.carrier_id > 2048)
                    return error.InvalidCarrier;
                if (payload.axis_id) |axis| {
                    if (axis == 0 or axis > Axis.max.line)
                        return error.InvalidTransitionAxis;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .push_carrier = .{
                                    .line_id = payload.line_id,
                                    .acceleration = payload.acceleration,
                                    .velocity = payload.velocity,
                                    .carrier_id = payload.carrier_id,
                                    .direction = payload.direction,
                                    .axis_id = payload.axis_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const pull_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.PullCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.direction == .DIRECTION_UNSPECIFIED)
                    return error.MissingDirection;
                if (payload.velocity == 0 or payload.velocity > 30)
                    return error.InvalidVelocity;
                if (payload.acceleration == 0 or payload.acceleration > 196)
                    return error.InvalidAcceleration;
                if (payload.carrier_id == 0 or payload.carrier_id > 2048)
                    return error.InvalidCarrier;
                if (payload.axis_id == 0 or payload.axis_id > Axis.max.line)
                    return error.InvalidPullingAxis;
                if (payload.transition) |transition| {
                    if (transition.control_kind == .CONTROL_UNSPECIFIED)
                        return error.InvalidControlKind;
                    if (transition.target) |target| {
                        switch (target) {
                            .axis => |axis| {
                                if (axis == 0 or axis > Axis.max.line)
                                    return error.InvalidAxisTarget;
                            },
                            else => {},
                        }
                    } else return error.MissingTarget;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .pull_carrier = .{
                                    .line_id = payload.line_id,
                                    .acceleration = payload.acceleration,
                                    .velocity = payload.velocity,
                                    .carrier_id = payload.carrier_id,
                                    .direction = payload.direction,
                                    .axis_id = payload.axis_id,
                                    .transition = payload.transition,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const isolate_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.IsolateCarrier,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.direction == .DIRECTION_UNSPECIFIED)
                    return error.MissingDirection;
                if (payload.carrier_id == 0 or payload.carrier_id > 2048)
                    return error.InvalidCarrier;
                if (payload.axis_id == 0 or payload.axis_id > Axis.max.line)
                    return error.InvalidPullingAxis;
                if (payload.link_axis) |link_axis|
                    if (link_axis == .DIRECTION_UNSPECIFIED)
                        return error.InvalidLinkDirection;
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .isolate_carrier = .{
                                    .line_id = payload.line_id,
                                    .carrier_id = payload.carrier_id,
                                    .direction = payload.direction,
                                    .axis_id = payload.axis_id,
                                    .link_axis = payload.link_axis,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const calibrate = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.Calibrate,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .calibrate = .{
                                    .line_id = payload.line_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const set_line_zero = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.SetLineZero,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .set_line_zero = .{
                                    .line_id = payload.line_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const clear_commands = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.command_msg.Request.ClearCommand,
            ) ![]const u8 {
                if (payload.command_id == 0 or payload.command_id > 4096)
                    return error.InvalidCommand;
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .command = .{
                            .body = .{
                                .clear_command = .{
                                    .command_id = payload.command_id,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
    };
    pub const info = struct {
        pub const commands = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.info_msg.Request.Command,
            ) ![]const u8 {
                if (payload.id) |id| {
                    if (id == 0 or id > 4096) return error.InvalidCommandID;
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .info = .{
                            .body = .{
                                .command = .{ .id = payload.id },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
            }
        };
        pub const system = struct {
            pub fn encode(
                allocator: std.mem.Allocator,
                payload: api.info_msg.Request.System,
            ) ![]const u8 {
                if (payload.line_id == 0 or payload.line_id > Line.max)
                    return error.InvalidLine;
                if (payload.source) |source| {
                    switch (source) {
                        .driver_range => |range| {
                            if (range.start_id == 0 or range.start_id > Driver.max)
                                return error.InvalidDriverRange;
                            if (range.end_id == 0 or range.end_id > Driver.max or
                                range.end_id < range.start_id)
                                return error.InvalidDriverRange;
                        },
                        .axis_range => |range| {
                            if (range.start_id == 0 or range.start_id > Axis.max.line)
                                return error.InvalidAxisRange;
                            if (range.end_id == 0 or range.end_id > Axis.max.line or
                                range.end_id < range.start_id)
                                return error.InvalidAxisRange;
                        },
                        .carriers => |carriers| {
                            for (carriers.ids.items) |carrier| {
                                if (carrier == 0 or carrier > 2048)
                                    return error.InvalidCarrierID;
                            }
                        },
                    }
                }
                const msg: api.mmc_msg.Request = .{
                    .body = .{
                        .info = .{
                            .body = .{
                                .system = .{
                                    .line_id = payload.line_id,
                                    .axis = payload.axis,
                                    .carrier = payload.carrier,
                                    .driver = payload.driver,
                                    .source = payload.source,
                                },
                            },
                        },
                    },
                };
                return try msg.encode(allocator);
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
