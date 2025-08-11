// This file purpose is an interface for parsing the response and creating a
// request to the server.
const std = @import("std");
const api = @import("mmc-api");
const Axis = @import("Axis.zig");
const Driver = @import("Driver.zig");
const Line = @import("Line.zig");
const Log = @import("Log.zig");

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
                        return try response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .line_config => |config| {
                            for (config.lines.items) |line| {
                                if (line.axes > std.math.maxInt(Axis.Id.Line))
                                    return error.InvalidAxesResponse;
                                if (line.length) |length| {
                                    if (length.axis == 0 and length.carrier)
                                        return error.InvalidLengthResponse;
                                } else return error.MissingConfiguration;
                                if (line.name.getSlice().len == 0)
                                    return error.MissingConfiguration;
                            }
                            return config;
                        },
                        .request_error => |req_err| {
                            return try core.error_handler(req_err);
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
                        return try response.error_handler(req_err);
                    },
                    .core => |core_resp| switch (core_resp.body orelse
                        return error.InvalidResponse) {
                        .api_version => |api_ver| {
                            if (api_ver.major == 0 and api_ver.minor == 0 and
                                api_ver.patch == 0) return error.InvalidVersionResponse;
                            return api_ver;
                        },
                        .request_error => |req_err| {
                            return try core.error_handler(req_err);
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
                        return try response.error_handler(req_err);
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
                            return try core.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        fn error_handler(err: api.core_msg.Response.RequestErrorKind) !void {
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
                        return try response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        .command_id => |comm_id| {
                            // ID is guaranteed to not be 0
                            if (comm_id == 0) error.InvalidIdResponse;
                            return comm_id;
                        },
                        .request_error => |req_err| {
                            return try command.error_handler(req_err);
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
                        return try response.error_handler(req_err);
                    },
                    .command => |command_resp| switch (command_resp.body orelse
                        return error.InvalidResponse) {
                        // TODO: The API shall change to bool
                        .command_operation => |status| {
                            return switch (status) {
                                .COMMAND_STATUS_UNSPECIFIED => return error.InvalidResponse,
                                .COMMAND_STATUS_COMPLETED => return true,
                            };
                        },
                        .request_error => |req_err| {
                            return try command.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        fn error_handler(err: api.core_msg.Response.RequestErrorKind) !void {
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
                        return try response.error_handler(req_err);
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
                            return try info.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }
        };
        pub const system = struct {
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
                        return try response.error_handler(req_err);
                    },
                    .info => |info_resp| switch (info_resp.body orelse
                        return error.InvalidResponse) {
                        .system => |system_resp| {
                            if (system_resp.line_id == 0 or
                                system_resp.line_id > Line.max)
                                return error.InvalidLineResponse;
                            for (system_resp.axis_errors.items) |axis_err| {
                                if (axis_err.id == 0 or
                                    axis_err.id > Axis.max.line)
                                    return error.InvalidAxisResponse;
                            }
                            for (system_resp.axis_infos.items) |axis_info| {
                                if (axis_info.id == 0 or
                                    axis_info.id > Axis.max.line)
                                    return error.InvalidAxisResponse;
                                if (axis_info.hall_alarm == null)
                                    return error.InvalidAxisResponse;
                                if (axis_info.carrier_id > 2048)
                                    return error.InvalidAxisResponse;
                            }
                            for (system_resp.driver_infos.items) |driver_info| {
                                if (driver_info.id == 0 or
                                    driver_info.id > Driver.max)
                                    return error.InvalidDriverResponse;
                            }
                            for (system_resp.driver_errors.items) |driver_error| {
                                if (driver_error.id == 0 or
                                    driver_error.id > Driver.max)
                                    return error.InvalidDriverResponse;
                                if (driver_error.communication_error == null)
                                    return error.InvalidDriverResponse;
                                if (driver_error.power_error == null)
                                    return error.InvalidDriverResponse;
                            }
                            for (system_resp.carrier_infos.items) |carrier| {
                                if (carrier.id == 0 or carrier.id > 2048)
                                    return error.InvalidCarrierResponse;
                                if (carrier.cas == null)
                                    return error.InvalidCarrierResponse;
                                if (carrier.axis) |axis| {
                                    if (axis.main == 0 or axis.main > Axis.max.line)
                                        return error.InvalidCarrierResponse;
                                    if (axis.auxiliary) |aux| {
                                        if (aux == 0 or aux > Axis.max.line)
                                            return error.InvalidCarrierResponse;
                                    }
                                } else return error.InvalidCarrierResponse;
                            }
                            return system_resp;
                        },
                        .request_error => |req_err| {
                            return try info.error_handler(req_err);
                        },
                        else => return error.InvalidResponse,
                    },
                    else => return error.InvalidResponse,
                }
            }

            // TODO: Finish these function when finishing logging function
            // pub fn decodeAndParseToLog(self: *Info.System) !Log.Data.Axis{}
            // pub fn decodeAndParseToLog(self: *Info.System) !Log.Data.Driver{}
        };
        fn error_handler(err: api.core_msg.Response.RequestErrorKind) !void {
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

    fn error_handler(err: api.mmc_msg.Response.RequestError) !void {
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
            fn encode(
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
                            if (range.end_id == 0 or range.end > Driver.max or
                                range.end_id < range.start_id)
                                return error.InvalidDriverRange;
                        },
                        .axis_range => |range| {
                            if (range.start_id == 0 or range.start_id > Axis.max.line)
                                return error.InvalidAxisRange;
                            if (range.end_id == 0 or range.end > Axis.max or
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
