// This file purpose is an interface for parsing the response and creating a
// request to the server.
const std = @import("std");
const Line = @import("Line.zig");
const Log = @import("Log.zig");

pub const api = @import("mmc-api");

pub const response = struct {
    pub const core = struct {
        pub const line_config = struct {
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.core_msg.Response.LineConfig {
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
                        .line_config => |config| return config,
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
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !bool {
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
                        .commands => |commands_resp| {
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
            /// Decode the response. Caller shall free the allocated memory.
            pub fn decode(
                allocator: std.mem.Allocator,
                reader: *std.Io.Reader,
            ) !api.info_msg.Response.System {
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
                        .system => |system_resp| return system_resp,
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
                result: *Log.Data,
            ) !void {
                const axis_infos = system_resp.axis_infos;
                const axis_errors = system_resp.axis_errors;
                const driver_infos = system_resp.driver_infos;
                const driver_errors = system_resp.driver_errors;
                const carriers = system_resp.carrier_infos;
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
                            .body = .{
                                .clear_errors = .{
                                    .line_id = payload.line_id,
                                    .driver_id = payload.driver_id,
                                },
                            },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const clear_carriers = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.ClearCarriers,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const release_control = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.ReleaseControl,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const stop_pull_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.StopPullCarrier,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const stop_push_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.StopPushCarrier,
            ) !void {
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
                            .body = .{
                                .auto_initialize = .{
                                    .lines = payload.lines,
                                },
                            },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const move_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.MoveCarrier,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const push_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.PushCarrier,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const pull_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.PullCarrier,
            ) !void {
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
                try msg.encode(writer, allocator);
            }
        };
        pub const isolate_carrier = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.IsolateCarrier,
            ) !void {
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
                            .body = .{
                                .calibrate = .{
                                    .line_id = payload.line_id,
                                },
                            },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const set_line_zero = struct {
            /// Validate payload and encode to protobuf string. Caller shall free
            /// the memory.
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.command_msg.Request.SetLineZero,
            ) !void {
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
                            .body = .{
                                .clear_command = .{
                                    .command_id = payload.command_id,
                                },
                            },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
    };
    pub const info = struct {
        pub const commands = struct {
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
                            .body = .{
                                .command = .{ .id = payload.id },
                            },
                        },
                    },
                };
                try msg.encode(writer, allocator);
            }
        };
        pub const system = struct {
            pub fn encode(
                allocator: std.mem.Allocator,
                writer: *std.Io.Writer,
                payload: api.info_msg.Request.System,
            ) !void {
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
