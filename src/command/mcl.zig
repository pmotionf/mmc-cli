const std = @import("std");
const command = @import("../command.zig");
const mcl = @import("mcl");
const mmc_api = @import("mmc_api");
const Board = @import("board-IF");
const soem = Board.soem;

var line_names: [][]u8 = undefined;
var line_speeds: []u7 = undefined;
var line_accelerations: []u7 = undefined;

const Direction = mcl.Direction;
const Distance = mcl.Distance;

const Ethercat = struct {
    board_if: Board,
    lines: []Line,

    /// Initialize ethercat connection and allocate required memories to store
    /// process data from ethercat.
    fn init(gpa: std.mem.Allocator, io: std.Io, config: Config) !Ethercat {
        var res: Ethercat = .{
            .board_if = undefined,
            .lines = &.{},
        };
        res.board_if = try .init(gpa, io);
        errdefer res.deinit(gpa);
        res.lines = try gpa.alloc(Line, config.lines.len);
        var station_count: usize = 0;
        for (res.lines, config.lines, 0..) |*line, line_config, line_idx| {
            try line.init(
                gpa,
                @intCast(line_idx),
                line_config.axes,
                res.board_if.ctx,
                res.board_if.lock,
                &station_count,
            );
        }
        return res;
    }

    fn deinit(self: *Ethercat, gpa: std.mem.Allocator) void {
        self.board_if.deinit(gpa);
        for (self.lines) |line| {
            line.deinit(gpa);
        }
        gpa.free(self.lines);
    }

    const Line = struct {
        index: Station.Index,
        id: Station.Id,
        axes: []Axis,
        stations: []Station,
        x: []Station.X,
        y: []Station.Y,
        wr: []Station.Wr,
        ww: []Station.Ww,

        fn init(
            result: *Line,
            gpa: std.mem.Allocator,
            line_index: Station.Index,
            axes: Axis.Id.OnLine,
            soem_ctx: *soem.ecx_contextt,
            lock: *std.Io.RwLock,
            station_count: *usize,
        ) !void {
            result.index = line_index;
            result.id = line_index + 1;
            result.axes = try gpa.alloc(Axis, axes);
            errdefer gpa.free(result.axes);
            const stations = (axes - 1) / Axis.max.station + 1;
            result.stations = try gpa.alloc(Station, stations);
            errdefer gpa.free(result.stations);
            result.x = try gpa.alloc(Station.X, result.stations.len);
            errdefer gpa.free(result.x);
            result.y = try gpa.alloc(Station.Y, result.stations.len);
            errdefer gpa.free(result.y);
            result.wr = try gpa.alloc(Station.Wr, result.stations.len);
            errdefer gpa.free(result.wr);
            result.ww = try gpa.alloc(Station.Ww, result.stations.len);
            errdefer gpa.free(result.ww);

            @memset(result.x, std.mem.zeroes(Station.X));
            @memset(result.y, std.mem.zeroes(Station.Y));
            @memset(result.wr, std.mem.zeroes(Station.Wr));
            @memset(result.ww, std.mem.zeroes(Station.Ww));

            var num_axes: usize = 0;
            for (0..stations) |station_i| {
                station_count.* += 1;
                const start_num_axes = num_axes;
                for (0..3) |axis_i| {
                    if (num_axes >= result.axes.len) break;
                    result.axes[num_axes] = .{
                        .station = &result.stations[station_i],
                        .index = .{
                            .station = @intCast(axis_i),
                            .line = @intCast(num_axes),
                        },
                        .id = .{
                            .station = @intCast(axis_i + 1),
                            .line = @intCast(num_axes + 1),
                        },
                    };
                    num_axes += 1;
                }
                result.stations[station_i] = .{
                    .line = result,
                    .index = @intCast(station_i),
                    .id = @intCast(station_i + 1),
                    .x = &result.x[station_i],
                    .y = &result.y[station_i],
                    .wr = &result.wr[station_i],
                    .ww = &result.ww[station_i],
                    .axes = result.axes[start_num_axes..num_axes],
                    .slave = &soem_ctx.slavelist[station_count.*],
                    .lock = lock,
                };
            }
        }

        fn deinit(self: Line, gpa: std.mem.Allocator) void {
            gpa.free(self.axes);
            gpa.free(self.stations);
            gpa.free(self.x);
            gpa.free(self.y);
            gpa.free(self.wr);
            gpa.free(self.ww);
        }

        fn pollWr(self: Line, io: std.Io) !void {
            for (self.stations) |station| {
                try station.pollWr(io);
            }
        }

        fn pollX(self: Line, io: std.Io) !void {
            for (self.stations) |station| {
                try station.pollX(io);
            }
        }

        fn poll(self: Line, io: std.Io) !void {
            for (self.stations) |station| {
                try station.poll(io);
            }
        }

        /// Return the axis of the specified slider, if found in the system. If the
        /// slider is split across two axes, then the auxiliary axis will be included
        /// in the result tuple.
        pub fn search(line: *const Line, slider_id: u16) ?struct { Axis, ?Axis } {
            var result: struct { Axis, ?Axis } = .{ undefined, null };

            for (line.axes) |axis| {
                const station = axis.station;
                const wr = station.wr;
                if (wr.slider_number.axis(axis.index.station) == slider_id) {
                    result.@"0" = axis;

                    if (axis.index.station == 2 and axis.id.line < line.axes.len) {
                        const next_axis = line.axes[axis.index.line + 1];
                        const next_station = next_axis.station;
                        const next_wr = next_station.wr;

                        if (next_wr.slider_number.axis(
                            next_axis.index.station,
                        ) == slider_id) {
                            result.@"1" = next_axis;
                        }
                    }

                    break;
                }
            } else {
                return null;
            }

            // If there are two detected contiguous axes, determine which is primary
            // and auxiliary.
            if (result.@"1") |*aux| {
                const main: *Axis = &result.@"0";
                const station = main.station;
                const wr = station.wr;
                const state = wr.slider_state.axis(main.index.station);
                if (state == .NextAxisAuxiliary or state == .NextAxisCompleted or
                    state == .PrevAxisAuxiliary or state == .PrevAxisCompleted)
                {
                    const temp = main.*;
                    main.* = aux.*;
                    aux.* = temp;
                } else if (state == .None) {
                    const aux_station: *const Station = aux.station;
                    const aux_wr = aux_station.wr;
                    const aux_state = aux_wr.slider_state.axis(aux.index.station);
                    if (aux_state != .None and
                        aux_state != .NextAxisAuxiliary and
                        aux_state != .NextAxisCompleted and
                        aux_state != .PrevAxisAuxiliary and
                        aux_state != .PrevAxisCompleted)
                    {
                        const temp = main.*;
                        main.* = aux.*;
                        aux.* = temp;
                    }
                }
            }

            return result;
        }
    };

    const Station = struct {
        line: *const Line,
        index: Index,
        id: Id,
        axes: []Axis,

        x: *X,
        y: *Y,
        wr: *Wr,
        ww: *Ww,
        slave: *soem.ec_slavet,

        lock: *std.Io.RwLock,

        const X = mcl.registers.X;
        const Y = mcl.registers.Y;
        const Wr = mcl.registers.Wr;
        const Ww = mcl.registers.Ww;

        /// Index within configured line, spanning across connection ranges.
        const Index = std.math.IntFittingRange(0, 64 * 4 - 1);
        const Id = std.math.IntFittingRange(1, 64 * 4);

        fn sendY(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            @memcpy(
                self.slave.outputs[0..@sizeOf(Station.Y)],
                std.mem.asBytes(self.y),
            );
        }

        fn sendWw(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            @memcpy(
                self.slave.outputs[@sizeOf(Station.Y) .. @sizeOf(Station.Y) + @sizeOf(Station.Ww)],
                std.mem.asBytes(self.ww),
            );
        }

        fn send(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            @memcpy(
                self.slave.outputs[0..@sizeOf(Station.Y)],
                std.mem.asBytes(self.y),
            );
            @memcpy(
                self.slave.outputs[@sizeOf(Station.Y) .. @sizeOf(Station.Y) + @sizeOf(Station.Ww)],
                std.mem.asBytes(self.ww),
            );
        }

        fn pollX(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            @memcpy(
                std.mem.asBytes(self.x),
                self.slave.inputs[0..@sizeOf(Station.X)],
            );
        }

        fn pollWr(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            @memcpy(
                std.mem.asBytes(self.wr),
                self.slave.inputs[@sizeOf(Station.X) .. @sizeOf(Station.X) + @sizeOf(Station.Wr)],
            );
        }

        fn pollY(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            @memcpy(
                std.mem.asBytes(self.y),
                self.slave.outputs[0..@sizeOf(Station.Y)],
            );
        }

        fn pollWw(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            @memcpy(
                std.mem.asBytes(self.ww),
                self.slave.outputs[@sizeOf(Station.Y) .. @sizeOf(Station.Y) + @sizeOf(Station.Ww)],
            );
        }

        fn poll(self: Station, io: std.Io) !void {
            // Ensure slave still in operational mode
            if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            @memcpy(
                std.mem.asBytes(self.x),
                self.slave.inputs[0..@sizeOf(Station.X)],
            );
            @memcpy(
                std.mem.asBytes(self.wr),
                self.slave.inputs[@sizeOf(Station.X) .. @sizeOf(Station.X) + @sizeOf(Station.Wr)],
            );
            @memcpy(
                std.mem.asBytes(self.y),
                self.slave.outputs[0..@sizeOf(Station.Y)],
            );
            @memcpy(
                std.mem.asBytes(self.ww),
                self.slave.outputs[@sizeOf(Station.Y) .. @sizeOf(Station.Y) + @sizeOf(Station.Ww)],
            );
        }
    };

    const Axis = struct {
        station: *const Station,
        index: Index,
        id: Id,

        const Index = struct {
            station: OnStation,
            line: OnLine,

            const OnStation = std.math.IntFittingRange(0, 2);
            const OnLine = std.math.IntFittingRange(0, 64 * 4 * 3 - 1);
        };

        const Id = struct {
            station: OnStation,
            line: OnLine,

            const OnStation = std.math.IntFittingRange(1, 3);
            const OnLine = std.math.IntFittingRange(1, 64 * 4 * 3);
        };
        const max = struct {
            const station: usize = 3;
            const line: usize = 64 * 4 * station;
        };
    };
};

var ethercat_future: ?std.Io.Future(@typeInfo(@TypeOf(Board.process)).@"fn".return_type.?) = null;
var ethercat: ?Ethercat = null;

pub const Config = struct {
    protocol: enum { cclink, ethercat } = .cclink,
    line_names: [][]const u8,
    lines: []mcl.Config.Line,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, c: Config) !void {
    if (c.lines.len != c.line_names.len) {
        return error.ConfigLineNumberOfLineNamesDoesNotMatch;
    }
    try mcl.Config.validate(.{ .lines = c.lines });
    if (c.protocol == .ethercat) {
        ethercat = try .init(gpa, io, c);
    } else {
        try mcl.init(gpa, .{ .lines = c.lines });
    }
    errdefer {
        if (ethercat) |*eth| {
            eth.deinit(gpa);
        }
    }

    line_names = try gpa.alloc([]u8, c.line_names.len);
    line_speeds = try gpa.alloc(u7, c.lines.len);
    line_accelerations = try gpa.alloc(u7, c.lines.len);
    for (0..c.lines.len) |i| {
        line_names[i] = try gpa.alloc(u8, c.line_names[i].len);
        @memcpy(line_names[i], c.line_names[i]);
        line_speeds[i] = 40;
        line_accelerations[i] = 40;
    }

    try command.registry.put(gpa, "MCL_VERSION", .{
        .name = "MCL_VERSION",
        .short_description = "Display the CC-Link version.",
        .long_description =
        \\Print the currently linked version of the CC-Link in Semantic Version
        \\format.
        ,
        .execute = &mclVersion,
    });
    errdefer _ = command.registry.orderedRemove("MCL_VERSION");
    try command.registry.put(gpa, "CONNECT", .{
        .name = "CONNECT",
        .short_description = "Connect MCL with motion system.",
        .long_description =
        \\Initialize MCL's connection with the motion system. This command
        \\should be run before any other MCL command, and also after any power
        \\cycle of the motion system.
        ,
        .execute = &mclConnect,
    });
    errdefer _ = command.registry.orderedRemove("CONNECT");
    try command.registry.put(gpa, "DISCONNECT", .{
        .name = "DISCONNECT",
        .short_description = "Disconnect MCL from motion system.",
        .long_description =
        \\End MCL's connection with the motion system. This command should be
        \\run after other MCL commands are completed.
        ,
        .execute = &mclDisconnect,
    });
    errdefer _ = command.registry.orderedRemove("DISCONNECT");
    try command.registry.put(gpa, "SET_SPEED", .{
        .name = "SET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "speed percentage" },
        },
        .short_description = "Set the speed of slider movement for a line.",
        .long_description =
        \\Set the speed of slider movement for a line. The line is referenced
        \\by its name. The speed must be a whole integer number between 1 and
        \\100, inclusive.
        ,
        .execute = &mclSetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("SET_SPEED");
    try command.registry.put(gpa, "SET_ACCELERATION", .{
        .name = "SET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "acceleration percentage" },
        },
        .short_description = "Set the acceleration of slider movement.",
        .long_description =
        \\Set the acceleration of slider movement for a line. The line is
        \\referenced by its name. The acceleration must be a whole integer
        \\number between 1 and 100, inclusive.
        ,
        .execute = &mclSetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("SET_ACCELERATION");
    try command.registry.put(gpa, "GET_SPEED", .{
        .name = "GET_SPEED",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the speed of slider movement for a line.",
        .long_description =
        \\Get the speed of slider movement for a line. The line is referenced
        \\by its name. The speed is a whole integer number between 1 and 100,
        \\inclusive.
        ,
        .execute = &mclGetSpeed,
    });
    errdefer _ = command.registry.orderedRemove("GET_SPEED");
    try command.registry.put(gpa, "GET_ACCELERATION", .{
        .name = "GET_ACCELERATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Get the acceleration of slider movement.",
        .long_description =
        \\Get the acceleration of slider movement for a line. The line is
        \\referenced by its name. The acceleration is a whole integer number
        \\between 1 and 100, inclusive.
        ,
        .execute = &mclGetAcceleration,
    });
    errdefer _ = command.registry.orderedRemove("GET_ACCELERATION");
    try command.registry.put(gpa, "PRINT_X", .{
        .name = "PRINT_X",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the X register of a station.",
        .long_description =
        \\Poll and print the X register of a station. The station X register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &mclStationX,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_X");
    try command.registry.put(gpa, "PRINT_Y", .{
        .name = "PRINT_Y",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Y register of a station.",
        .long_description =
        \\Poll and print the Y register of a station. The station Y register to
        \\be printed is determined by the provided axis.
        ,
        .execute = &mclStationY,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_Y");
    try command.registry.put(gpa, "PRINT_WR", .{
        .name = "PRINT_WR",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Wr register of a station.",
        .long_description =
        \\Poll and print the Wr register of a station. The station Wr register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &mclStationWr,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_WR");
    try command.registry.put(gpa, "PRINT_WW", .{
        .name = "PRINT_WW",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Poll and print the Ww register of a station.",
        .long_description =
        \\Poll and print the Ww register of a station. The station Ww register
        \\to be printed is determined by the provided axis.
        ,
        .execute = &mclStationWw,
    });
    errdefer _ = command.registry.orderedRemove("PRINT_WW");
    try command.registry.put(gpa, "AXIS_SLIDER", .{
        .name = "AXIS_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "result variable", .optional = true, .resolve = false },
        },
        .short_description = "Display slider on given axis, if exists.",
        .long_description =
        \\If a slider is recognized on the provided axis, print its slider ID.
        \\If a result variable name was provided, also store the slider ID in
        \\the variable.
        ,
        .execute = &mclAxisSlider,
    });
    errdefer _ = command.registry.orderedRemove("AXIS_SLIDER");
    try command.registry.put(gpa, "SLIDER_LOCATION", .{
        .name = "SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Display a slider's location.",
        .long_description =
        \\Print a given slider's location if it is currently recognized in the
        \\provided line. If a result variable name is provided, then store the
        \\slider's location in the variable.
        ,
        .execute = &mclSliderLocation,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_LOCATION");
    try command.registry.put(gpa, "SLIDER_AXIS", .{
        .name = "SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Display a slider's axis/axes.",
        .long_description =
        \\Print a given slider's axis if it is currently recognized in the
        \\provided line. If the slider is currently recognized across two axes,
        \\then both axes will be printed.
        ,
        .execute = &mclSliderAxis,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_AXIS");
    try command.registry.put(gpa, "HALL_STATUS", .{
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
        .execute = &mclHallStatus,
    });
    errdefer _ = command.registry.orderedRemove("HALL_STATUS");
    try command.registry.put(gpa, "ASSERT_HALL", .{
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
        .execute = &mclAssertHall,
    });
    errdefer _ = command.registry.orderedRemove("ASSERT_HALL");
    try command.registry.put(gpa, "CLEAR_ERRORS", .{
        .name = "CLEAR_ERRORS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Clear driver errors of specified axis.",
        .long_description =
        \\Clear driver errors of specified axis.
        ,
        .execute = &mclClearErrors,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_ERRORS");
    try command.registry.put(gpa, "CLEAR_SLIDER_INFO", .{
        .name = "CLEAR_SLIDER_INFO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Clear slider information at specified axis.",
        .long_description =
        \\Clear slider information at specified axis.
        ,
        .execute = &mclClearSliderInfo,
    });
    errdefer _ = command.registry.orderedRemove("CLEAR_SLIDER_INFO");
    try command.registry.put(gpa, "RELEASE_AXIS_SERVO", .{
        .name = "RELEASE_AXIS_SERVO",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Release the servo of a given axis.",
        .long_description =
        \\Release the servo of a given axis, allowing for free slider movement.
        \\This command should be run before sliders move within or exit from
        \\the system due to external influence.
        ,
        .execute = &mclAxisReleaseServo,
    });
    errdefer _ = command.registry.orderedRemove("RELEASE_AXIS_SERVO");
    try command.registry.put(gpa, "STOP_TRAFFIC", .{
        .name = "STOP_TRAFFIC",
        .parameters = &.{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
        },
        .short_description = "Prevent traffic communication to controller.",
        .long_description =
        \\Forcibly stop all traffic transmission from the specified axis's
        \\controller to its neighboring controller. The neighboring controller
        \\is determined by the provided direction.
        ,
        .execute = &mclTrafficStop,
    });
    errdefer _ = command.registry.orderedRemove("STOP_TRAFFIC");
    try command.registry.put(gpa, "ALLOW_TRAFFIC", .{
        .name = "ALLOW_TRAFFIC",
        .parameters = &.{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
        },
        .short_description = "Resume traffic communication to controller.",
        .long_description =
        \\Permit all traffic transmission from the specified axis's controller
        \\to its neighboring controller. The neighboring controller is
        \\determined by the provided direction.
        ,
        .execute = &mclTrafficAllow,
    });
    errdefer _ = command.registry.orderedRemove("ALLOW_TRAFFIC");
    try command.registry.put(gpa, "CALIBRATE", .{
        .name = "CALIBRATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Calibrate a system line.",
        .long_description =
        \\Calibrate a system line. An uninitialized slider must be positioned
        \\at the start of the line such that the first axis has both hall
        \\alarms active.
        ,
        .execute = &mclCalibrate,
    });
    errdefer _ = command.registry.orderedRemove("CALIBRATE");
    try command.registry.put(gpa, "HOME_SLIDER", .{
        .name = "HOME_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
        },
        .short_description = "Home an unrecognized slider on the first axis.",
        .long_description =
        \\Home an unrecognized slider on the first axis. The unrecognized
        \\slider must be positioned in the correct homing position.
        ,
        .execute = &mclHomeSlider,
    });
    errdefer _ = command.registry.orderedRemove("HOME_SLIDER");
    try command.registry.put(gpa, "WAIT_HOME_SLIDER", .{
        .name = "WAIT_HOME_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Wait until homing of slider is complete.",
        .long_description =
        \\Wait until homing is complete and a slider is recognized on the first
        \\axis. If an optional result variable name is provided, then store the
        \\recognized slider ID in the variable.
        ,
        .execute = &mclWaitHomeSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_HOME_SLIDER");
    try command.registry.put(gpa, "ISOLATE", .{
        .name = "ISOLATE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "direction" },
            .{ .name = "slider id", .optional = true },
            .{ .name = "link axis", .resolve = false, .optional = true },
        },
        .short_description = "Isolate an uninitialized slider backwards.",
        .long_description =
        \\Slowly move an uninitialized slider to separate it from other nearby
        \\sliders. A direction of "backward" or "forward" must be provided. A
        \\slider ID can be optionally specified to give the isolated slider an
        \\ID other than the default temporary ID 255, and the next or previous
        \\can also be linked for isolation movement. Linked axis parameter
        \\values must be one of "prev", "next", "left", or "right".
        ,
        .execute = &mclIsolate,
    });
    errdefer _ = command.registry.orderedRemove("ISOLATE");
    try command.registry.put(gpa, "RECOVER_SLIDER", .{
        .name = "RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "new slider ID" },
            .{ .name = "use sensor", .resolve = false, .optional = true },
        },
        .short_description = "Recover an unrecognized slider on a given axis.",
        .long_description =
        \\Recover an unrecognized slider on a given axis. The provided slider
        \\ID must be a positive integer from 1 to 254 inclusive, and must be
        \\unique to other recognized slider IDs. If a sensor is optionally
        \\specified for use (valid sensor values include: front, back, left,
        \\right), recovery will use the specified hall sensor.
        ,
        .execute = &mclRecoverSlider,
    });
    errdefer _ = command.registry.orderedRemove("RECOVER_SLIDER");
    try command.registry.put(gpa, "WAIT_RECOVER_SLIDER", .{
        .name = "WAIT_RECOVER_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "result variable", .resolve = false, .optional = true },
        },
        .short_description = "Wait until recovery of slider is complete.",
        .long_description =
        \\Wait until slider recovery is complete and a slider is recognized.
        \\If an optional result variable name is provided, then store the
        \\recognized slider ID in the variable.
        ,
        .execute = &mclWaitRecoverSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_RECOVER_SLIDER");
    try command.registry.put(gpa, "MOVE_SLIDER_AXIS", .{
        .name = "MOVE_SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move slider to target axis center.",
        .long_description =
        \\Move given slider to the center of target axis. The slider ID must be
        \\currently recognized within the motion system.
        ,
        .execute = &mclSliderPosMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_AXIS");
    try command.registry.put(gpa, "MOVE_SLIDER_LOCATION", .{
        .name = "MOVE_SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination location" },
        },
        .short_description = "Move slider to target location.",
        .long_description =
        \\Move given slider to target location. The slider ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number.
        ,
        .execute = &mclSliderPosMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_LOCATION");
    try command.registry.put(gpa, "MOVE_SLIDER_DISTANCE", .{
        .name = "MOVE_SLIDER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "distance" },
        },
        .short_description = "Move slider by a distance.",
        .long_description =
        \\Move given slider by a provided distance. The slider ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement.
        ,
        .execute = &mclSliderPosMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_DISTANCE");
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_AXIS", .{
        .name = "SPD_MOVE_SLIDER_AXIS",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move slider to target axis center.",
        .long_description =
        \\Move given slider to the center of target axis. The slider ID must be
        \\currently recognized within the motion system. This command moves the
        \\slider with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveAxis,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_AXIS");
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_LOCATION", .{
        .name = "SPD_MOVE_SLIDER_LOCATION",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "destination location" },
        },
        .short_description = "Move slider to target location.",
        .long_description =
        \\Move given slider to target location. The slider ID must be currently
        \\recognized within the motion system, and the target location must be
        \\provided in millimeters as a whole or decimal number. This command
        \\moves the slider with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveLocation,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_LOCATION");
    try command.registry.put(gpa, "SPD_MOVE_SLIDER_DISTANCE", .{
        .name = "SPD_MOVE_SLIDER_DISTANCE",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
            .{ .name = "distance" },
        },
        .short_description = "Move slider by a distance.",
        .long_description =
        \\Move given slider by a provided distance. The slider ID must be
        \\currently recognized within the motion system, and the distance must
        \\be provided in millimeters as a whole or decimal number. The distance
        \\may be negative for backward movement. This command moves the slider
        \\with speed profile feedback.
        ,
        .execute = &mclSliderSpdMoveDistance,
    });
    errdefer _ = command.registry.orderedRemove("SPD_MOVE_SLIDER_DISTANCE");
    try command.registry.put(gpa, "WAIT_MOVE_SLIDER", .{
        .name = "WAIT_MOVE_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Wait for slider movement to complete.",
        .long_description =
        \\Pause the execution of any further commands until movement for the
        \\given slider is indicated as complete.
        ,
        .execute = &mclWaitMoveSlider,
    });
    errdefer _ = command.registry.orderedRemove("WAIT_MOVE_SLIDER");
    try command.registry.put(gpa, "PUSH_SLIDER_FORWARD", .{
        .name = "PUSH_SLIDER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Push slider forward by slider length.",
        .long_description =
        \\Push slider forward with speed feedback-controlled movement. This
        \\movement targets a distance of the slider length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the slider.
        ,
        .execute = &mclSliderPushForward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_FORWARD");
    try command.registry.put(gpa, "PUSH_SLIDER_BACKWARD", .{
        .name = "PUSH_SLIDER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "slider" },
        },
        .short_description = "Push slider backward by slider length.",
        .long_description =
        \\Push slider backward with speed feedback-controlled movement. This
        \\movement targets a distance of the slider length, and thus if it is
        \\used to cross a line boundary, the receiving axis at the destination
        \\line must first be pulling the slider.
        ,
        .execute = &mclSliderPushBackward,
    });
    errdefer _ = command.registry.orderedRemove("PUSH_SLIDER_BACKWARD");
    try command.registry.put(gpa, "PULL_SLIDER_FORWARD", .{
        .name = "PULL_SLIDER_FORWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
            .{ .name = "location" },
        },
        .short_description = "Pull incoming slider forward at axis.",
        .long_description =
        \\Pull incoming slider forward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_SLIDER" command.
        \\The pulled slider's ID must also be provided.
        ,
        .execute = &mclSliderPullForward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_SLIDER_FORWARD");
    try command.registry.put(gpa, "PULL_SLIDER_BACKWARD", .{
        .name = "PULL_SLIDER_BACKWARD",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
            .{ .name = "slider" },
            .{ .name = "location" },
        },
        .short_description = "Pull incoming slider backward at axis.",
        .long_description =
        \\Pull incoming slider backward at axis. This command must be stopped
        \\manually after it is completed with the "STOP_PULL_SLIDER" command.
        \\The pulled slider's ID must also be provided.
        ,
        .execute = &mclSliderPullBackward,
    });
    errdefer _ = command.registry.orderedRemove("PULL_SLIDER_BACKWARD");
    try command.registry.put(gpa, "WAIT_PULL_SLIDER", .{
        .name = "WAIT_PULL_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Wait for slider pull to complete.",
        .long_description =
        \\Pause the execution of any further commands until active slider pull
        \\at the provided axis is indicated as complete.
        ,
        .execute = &mclSliderWaitPull,
    });
    try command.registry.put(gpa, "STOP_PULL_SLIDER", .{
        .name = "STOP_PULL_SLIDER",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Stop active slider pull at axis.",
        .long_description =
        \\Stop active slider pull at axis.
        ,
        .execute = &mclSliderStopPull,
    });
    errdefer _ = command.registry.orderedRemove("STOP_PULL_SLIDER");
    try command.registry.put(gpa, "SLIDER_CHAIN_LINK", .{
        .name = "SLIDER_CHAIN_LINK",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "first axis" },
            .{ .name = "second axis" },
        },
        .short_description = "Link sliders on two axes in a chain.",
        .long_description =
        \\Link sliders on two axes in a chain.
        ,
        .execute = &mclSliderChainLink,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_CHAIN_LINK");
    try command.registry.put(gpa, "SLIDER_CHAIN_UNLINK", .{
        .name = "SLIDER_CHAIN_UNLINK",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "first axis" },
            .{ .name = "second axis" },
        },
        .short_description = "Unlink sliders on two axes from a chain.",
        .long_description =
        \\Unlink sliders on two axes from a chain.
        ,
        .execute = &mclSliderChainUnlink,
    });
    errdefer _ = command.registry.orderedRemove("SLIDER_CHAIN_UNLINK");
    try command.registry.put(gpa, "SET_LEFT_CHAIN_ON", .{
        .name = "SET_LEFT_CHAIN_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Link sliders on axis and backwards axis.",
        .long_description =
        \\Link sliders on axis and backwards axis.
        ,
        .execute = &mclSetLeftChainOn,
    });
    errdefer _ = command.registry.orderedRemove("SET_LEFT_CHAIN_ON");
    try command.registry.put(gpa, "SET_RIGHT_CHAIN_ON", .{
        .name = "SET_RIGHT_CHAIN_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Link sliders on axis and forwards axis.",
        .long_description =
        \\Link sliders on axis and forwards axis.
        ,
        .execute = &mclSetRightChainOn,
    });
    errdefer _ = command.registry.orderedRemove("SET_RIGHT_CHAIN_ON");
    try command.registry.put(gpa, "SET_LEFT_CHAIN_OFF", .{
        .name = "SET_LEFT_CHAIN_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Unlink sliders on axis and backwards axis.",
        .long_description =
        \\Unlink sliders on axis and backwards axis.
        ,
        .execute = &mclSetLeftChainOff,
    });
    errdefer _ = command.registry.orderedRemove("SET_LEFT_CHAIN_OFF");
    try command.registry.put(gpa, "SET_RIGHT_CHAIN_OFF", .{
        .name = "SET_RIGHT_CHAIN_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "axis" },
        },
        .short_description = "Unlink sliders on axis and forwards axis.",
        .long_description =
        \\Unlink sliders on axis and forwards axis.
        ,
        .execute = &mclSetRightChainOff,
    });
    errdefer _ = command.registry.orderedRemove("SET_RIGHT_CHAIN_OFF");
    try command.registry.put(gpa, "MOVE_SLIDER_CHAIN", .{
        .name = "MOVE_SLIDER_CHAIN",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name" },
            .{ .name = "head slider ID" },
            .{ .name = "destination axis" },
        },
        .short_description = "Move chain linked sliders to axis.",
        .long_description =
        \\Move chain linked sliders to axis.
        ,
        .execute = &mclMoveSliderChain,
    });
    errdefer _ = command.registry.orderedRemove("MOVE_SLIDER_CHAIN");
    try command.registry.put(gpa, "EMERGENCY_STOP_ON", .{
        .name = "EMERGENCY_STOP_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Stop all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Enable emergency stop on all drivers.
            \\Optional: Enable emergency stop only on specified line.
        , .{}),
        .execute = &mclStopOn,
    });
    errdefer _ = command.registry.orderedRemove("EMERGENCY_STOP_ON");
    try command.registry.put(gpa, "PAUSE_ON", .{
        .name = "PAUSE_ON",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Pause all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Enable pause on all drivers.
            \\Optional: Enable pause only on specified Line.
        , .{}),
        .execute = &mclPauseOn,
    });
    errdefer _ = command.registry.orderedRemove("PAUSE_ON");
    try command.registry.put(gpa, "EMERGENCY_STOP_OFF", .{
        .name = "EMERGENCY_STOP_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Stop all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Disable emergency stop on all drivers.
            \\Optional: Disable emergency stop only on specified Line.
        , .{}),
        .execute = &mclStopOff,
    });
    errdefer _ = command.registry.orderedRemove("EMERGENCY_STOP_OFF");
    try command.registry.put(gpa, "PAUSE_OFF", .{
        .name = "PAUSE_OFF",
        .parameters = &[_]command.Command.Parameter{
            .{ .name = "line name", .optional = true },
        },
        .short_description = "Pause all processes.",
        .long_description = std.fmt.comptimePrint(
            \\Disable pause on all drivers.
            \\Optional: Disable pause only on specified Line.
        , .{}),
        .execute = &mclPauseOff,
    });
    errdefer _ = command.registry.orderedRemove("PAUSE_OFF");
}

pub fn deinit(gpa: std.mem.Allocator, io: std.Io) void {
    gpa.free(line_names);
    gpa.free(line_speeds);
    gpa.free(line_accelerations);
    if (ethercat) |*eth| {
        if (eth.board_if.ctx.slavelist[0].state != 0) {
            eth.board_if.close(io) catch {};
        }
        eth.deinit(gpa);
    } else {
        mcl.deinit();
    }
}

fn mclVersion(_: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    std.log.info("CC-Link Version: {d}.{d}.{d}\n", .{
        mcl.version.major,
        mcl.version.minor,
        mcl.version.patch,
    });
}

fn mclConnect(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    if (ethercat) |*eth| {
        try eth.board_if.open(io);
        errdefer eth.board_if.close(io) catch {};
        ethercat_future = try io.concurrent(
            Board.process,
            .{ io, &eth.board_if },
        );
        while (eth.board_if.ctx.slavelist[0].state != soem.EC_STATE_OPERATIONAL) {
            _ = soem.ecx_readstate(eth.board_if.ctx);
            try command.checkCommandInterrupt();
        }
        for (eth.lines) |line| {
            for (line.stations) |station| {
                station.y.cc_link_enable = true;
                try station.send(io);
            }
        }
        return;
    }
    try mcl.open();
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = true;
            try station.send();
        }
    }
}

fn mclDisconnect(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    if (ethercat) |*eth| {
        for (eth.lines) |line| {
            for (line.stations) |station| {
                station.y.cc_link_enable = false;
                try station.send(io);
            }
        }
        try eth.board_if.switchState(io, soem.EC_STATE_INIT);
        return;
    }
    for (mcl.lines) |line| {
        for (line.stations) |station| {
            station.y.cc_link_enable = false;
            try station.send();
        }
    }
    try mcl.close();
}

fn mclStationX(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const station = line.axes[@intCast(axis_id - 1)].station;
        try station.pollX(io);
        std.log.info("{f}", .{station.x});
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: mcl.Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollX();

    std.log.info("{f}", .{line.stations[station_index].x});
}

fn mclStationY(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);

    if (ethercat) |eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const station = line.axes[@intCast(axis_id - 1)].station;
        try station.pollY(io);
        std.log.info("{f}", .{station.y});
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: mcl.Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollY();

    std.log.info("{f}", .{line.stations[station_index].y});
}

fn mclStationWr(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const station = line.axes[@intCast(axis_id - 1)].station;
        try station.pollWr(io);
        std.log.info("{f}", .{station.wr});
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: mcl.Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollWr();

    std.log.info("{f}", .{line.stations[station_index].wr});
}

fn mclStationWw(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }
        const station = line.axes[@intCast(axis_id - 1)].station;
        try station.pollWw(io);
        std.log.info("{f}", .{station.ww});
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis: mcl.Axis.Index.Line = @intCast(axis_id - 1);

    const station_index: mcl.Station.Index = @intCast(axis / 3);
    try line.stations[station_index].pollWw();

    std.log.info("{f}", .{line.stations[station_index].ww});
}

fn mclAxisSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id = try std.fmt.parseInt(i16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line_idx = try matchLine(line_names, line_name);
    const slider_id = slider: {
        if (ethercat) |eth| {
            const line = eth.lines[line_idx];

            if (axis_id < 1 or axis_id > line.axes.len) {
                return error.InvalidAxis;
            }

            const axis = line.axes[@intCast(axis_id - 1)];
            const station = axis.station;
            try station.pollWr(io);

            break :slider station.wr.slider_number.axis(axis.index.station);
        } else {
            const line = mcl.lines[line_idx];

            if (axis_id < 1 or axis_id > line.axes.len) {
                return error.InvalidAxis;
            }

            const axis = line.axes[@intCast(axis_id - 1)];
            const station = axis.station;
            try station.pollWr();

            break :slider station.wr.slider_number.axis(axis.index.station);
        }
    };

    if (slider_id != 0) {
        std.log.info("Slider {d} on axis {d}.\n", .{ slider_id, axis_id });
        if (result_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                result_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
            );
        }
    } else {
        std.log.info("No slider recognized on axis {d}.\n", .{axis_id});
    }
}

fn mclAxisReleaseServo(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);

    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        station.y.servo_release = true;
        try station.sendY(io);
        defer {
            station.y.servo_release = false;
            station.sendY(io) catch {};
        }
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            if (!station.x.servo_active.axis(axis.index.station)) break;
        }
        return;
    }

    const line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try station.setY(0x6);
    // Reset on error as well as on success.
    defer station.resetY(0x6) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (!station.x.servo_active.axis(local_axis_index)) break;
    }
}

fn mclClearErrors(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        station.ww.target_axis_number = axis.id.station;
        station.y.clear_errors = true;
        try station.send(io);
        defer {
            station.y.clear_errors = false;
            station.sendY(io) catch {};
        }
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            if (!station.x.errors_cleared) break;
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    station.ww.target_axis_number = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0xB);
    // Reset on error as well as on success.
    defer station.resetY(0xB) catch {};
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.errors_cleared) break;
    }
}

fn mclClearSliderInfo(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: i16 = try std.fmt.parseInt(i16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id < 1 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        station.ww.target_axis_number = axis.id.station;
        station.y.clear_axis_slider_info = true;
        try station.send(io);
        defer {
            station.y.clear_axis_slider_info = false;
            station.sendY(io) catch {};
        }
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            if (!station.x.axis_slider_info_cleared) break;
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id < 1 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const station = line.stations[axis_index / 3];
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    station.ww.target_axis_number = local_axis_index + 1;
    try station.sendWw();
    try station.setY(0xC);
    // Reset on error as well as on success.
    defer station.resetY(0xC) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (station.x.axis_slider_info_cleared) break;
    }
}

fn mclCalibrate(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        const station = line.stations[0];
        try waitCommandReady(io, line_idx, station.index);
        station.ww.command_code = .Calibration;
        station.ww.command_slider_number = 1;
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    const station = line.stations[0];
    try waitCommandReady(io, line_idx, station.index);
    station.ww.command_code = .Calibration;
    station.ww.command_slider_number = 1;
    try sendCommand(io, line_idx, station.index);
}

fn mclHomeSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        const station = line.stations[0];
        try waitCommandReady(io, line_idx, station.index);
        station.ww.command_code = .Home;
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    const station = line.stations[0];

    try waitCommandReady(io, line_idx, station.index);
    station.ww.command_code = .Home;
    try sendCommand(io, line_idx, station.index);
}

fn mclWaitHomeSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const result_var: []const u8 = params[1];

    const line_idx = try matchLine(line_names, line_name);
    const slider = slider: {
        if (ethercat) |*eth| {
            const line = eth.lines[line_idx];

            const station = line.stations[0];

            while (true) {
                try command.checkCommandInterrupt();
                try station.pollWr(io);

                if (station.wr.slider_number.axis1 != 0) {
                    break :slider station.wr.slider_number.axis1;
                }
            }
        } else {
            const line = mcl.lines[line_idx];

            const station = line.stations[0];

            while (true) {
                try command.checkCommandInterrupt();
                try station.pollWr();

                if (station.wr.slider_number.axis1 != 0) {
                    break :slider station.wr.slider_number.axis1;
                }
            }
        }
    };

    std.log.info("Slider {d} homed.\n", .{slider});
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{slider}),
        );
    }
}

fn mclIsolate(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: u16 = try std.fmt.parseInt(u16, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const dir: Direction = dir_parse: {
            if (std.ascii.eqlIgnoreCase("forward", params[2])) {
                break :dir_parse .forward;
            } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
                break :dir_parse .backward;
            } else {
                return error.InvalidDirection;
            }
        };

        const slider_id: u16 = if (params[3].len > 0)
            try std.fmt.parseInt(u16, params[3], 0)
        else
            0;
        const link_axis: ?Direction = link: {
            if (params[4].len > 0) {
                if (std.ascii.eqlIgnoreCase("next", params[4]) or
                    std.ascii.eqlIgnoreCase("right", params[4]))
                {
                    break :link .forward;
                } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                    std.ascii.eqlIgnoreCase("left", params[4]))
                {
                    break :link .backward;
                } else return error.InvalidIsolateLinkAxis;
            } else break :link null;
        };

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;

        try waitCommandReady(io, line_idx, station.index);
        if (link_axis) |a| {
            if (a == .backward) {
                station.y.prev_axis_isolate_link = true;
            } else {
                station.y.next_axis_isolate_link = true;
            }
            try station.sendY(io);
        }
        defer {
            if (link_axis) |a| {
                if (a == .backward) {
                    station.y.prev_axis_isolate_link = false;
                } else {
                    station.y.next_axis_isolate_link = false;
                }
                station.sendY(io) catch {};
            }
        }
        station.ww.* = .{
            .command_code = if (dir == .forward)
                .IsolateForward
            else
                .IsolateBackward,
            .command_slider_number = slider_id,
            .target_axis_number = axis.id.station,
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const dir: Direction = dir_parse: {
        if (std.ascii.eqlIgnoreCase("forward", params[2])) {
            break :dir_parse .forward;
        } else if (std.ascii.eqlIgnoreCase("backward", params[2])) {
            break :dir_parse .backward;
        } else {
            return error.InvalidDirection;
        }
    };

    const slider_id: u16 = if (params[3].len > 0)
        try std.fmt.parseInt(u16, params[3], 0)
    else
        0;
    const link_axis: ?Direction = link: {
        if (params[4].len > 0) {
            if (std.ascii.eqlIgnoreCase("next", params[4]) or
                std.ascii.eqlIgnoreCase("right", params[4]))
            {
                break :link .forward;
            } else if (std.ascii.eqlIgnoreCase("prev", params[4]) or
                std.ascii.eqlIgnoreCase("left", params[4]))
            {
                break :link .backward;
            } else return error.InvalidIsolateLinkAxis;
        } else break :link null;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis_id - 1);
    const station = line.stations[axis_index / 3];
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    try waitCommandReady(io, line_idx, station.index);
    if (link_axis) |a| {
        if (a == .backward) {
            try station.setY(0xD);
            station.y.prev_axis_isolate_link = true;
        } else {
            try station.setY(0xE);
            station.y.next_axis_isolate_link = true;
        }
    }
    defer {
        if (link_axis) |a| {
            if (a == .backward) {
                if (station.resetY(0xD)) {
                    station.y.prev_axis_isolate_link = false;
                } else |_| {}
            } else {
                if (station.resetY(0xE)) {
                    station.y.next_axis_isolate_link = false;
                } else |_| {}
            }
        }
    }
    station.ww.* = .{
        .command_code = if (dir == .forward)
            .IsolateForward
        else
            .IsolateBackward,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSetSpeed(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_speed = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_speed < 1 or slider_speed > 100) return error.InvalidSpeed;

    const line_idx = try matchLine(line_names, line_name);
    line_speeds[line_idx] = @intCast(slider_speed);
}

fn mclSetAcceleration(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_acceleration = try std.fmt.parseUnsigned(u8, params[1], 0);
    if (slider_acceleration < 1 or slider_acceleration > 100)
        return error.InvalidAcceleration;

    const line_idx = try matchLine(line_names, line_name);
    line_accelerations[line_idx] = @intCast(slider_acceleration);
}

fn mclGetSpeed(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try matchLine(line_names, line_name);
    std.log.info("Line {s} speed: {d}%", .{ line_name, line_speeds[line_idx] });
}

fn mclGetAcceleration(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];

    const line_idx = try matchLine(line_names, line_name);
    std.log.info(
        "Line {s} acceleration: {d}%",
        .{ line_name, line_accelerations[line_idx] },
    );
}

fn mclSliderLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;
    const result_var: []const u8 = params[2];

    const line_idx = try matchLine(line_names, line_name);
    const location = location: {
        if (ethercat) |*eth| {
            const line = eth.lines[line_idx];

            try line.pollWr(io);
            const main, _ =
                if (line.search(slider_id)) |t| t else return error.SliderNotFound;

            const station = main.station;

            break :location station.wr.slider_location.axis(main.index.station);
        } else {
            const line = mcl.lines[line_idx];

            try line.pollWr();
            const main, _ =
                if (line.search(slider_id)) |t| t else return error.SliderNotFound;

            const station = main.station;

            break :location station.wr.slider_location.axis(main.index.station);
        }
    };

    std.log.info(
        "Slider {d} location: {d}.{d}mm",
        .{ slider_id, location.mm, location.um },
    );
    if (result_var.len > 0) {
        var float_buf: [12]u8 = undefined;
        try command.variables.put(result_var, try std.fmt.bufPrint(
            &float_buf,
            "{d}.{d}",
            .{ location.mm, location.um },
        ));
    }
}

fn mclSliderAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);

        var axis: mcl.Axis.Id.Line = 1;
        for (line.stations) |station| {
            for (0..3) |_local_axis| {
                const local_axis: mcl.Axis.Index.Station = @intCast(_local_axis);
                if (station.wr.slider_number.axis(local_axis) == slider_id) {
                    std.log.info(
                        "Slider {d} axis: {}",
                        .{ slider_id, axis },
                    );
                }
                axis += 1;
                if (axis > line.axes.len) break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();

    var axis: mcl.Axis.Id.Line = 1;
    for (line.stations) |station| {
        for (0..3) |_local_axis| {
            const local_axis: mcl.Axis.Index.Station = @intCast(_local_axis);
            if (station.wr.slider_number.axis(local_axis) == slider_id) {
                std.log.info(
                    "Slider {d} axis: {}",
                    .{ slider_id, axis },
                );
            }
            axis += 1;
            if (axis > line.axes.len) break;
        }
    }
}

fn mclHallStatus(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: ?mcl.Axis.Id.Line = if (params[1].len > 0)
        try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0)
    else
        null;
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id) |id| {
            if (id == 0 or id > line.axes.len) {
                return error.InvalidAxis;
            }
        }

        try line.pollX(io);
        if (axis_id) |id| {
            const axis = line.axes[id - 1];
            const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
            if (alarms.back) {
                std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
            }
            if (alarms.front) {
                std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
            }
        } else for (line.stations) |station| {
            for (station.axes) |axis| {
                const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
                if (alarms.back) {
                    std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
                }
                if (alarms.front) {
                    std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
                }
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id) |id| {
        if (id == 0 or id > line.axes.len) {
            return error.InvalidAxis;
        }
    }

    try line.pollX();
    if (axis_id) |id| {
        const axis = line.axes[id - 1];
        const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
        if (alarms.back) {
            std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
        }
        if (alarms.front) {
            std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
        }
    } else for (line.stations) |station| {
        for (station.axes) |axis| {
            const alarms = axis.station.x.hall_alarm.axis(axis.index.station);
            if (alarms.back) {
                std.log.info("Axis {} Hall Sensor: BACK - ON", .{axis.id.line});
            }
            if (alarms.front) {
                std.log.info("Axis {} Hall Sensor: FRONT - ON", .{axis.id.line});
            }
        }
    }
}

fn mclAssertHall(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseInt(mcl.Axis.Id.Line, params[1], 0);
    const side: mcl.Direction =
        if (std.ascii.eqlIgnoreCase("back", params[2]) or
        std.ascii.eqlIgnoreCase("left", params[2]))
            .backward
        else if (std.ascii.eqlIgnoreCase("front", params[2]) or
        std.ascii.eqlIgnoreCase("right", params[2]))
            .forward
        else
            return error.InvalidHallAlarmSide;
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis == 0 or axis > line.axes.len) {
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

        const station_ind: mcl.Station.Index = @intCast((axis - 1) / 3);
        const local_axis: mcl.Axis.Index.Station = @intCast((axis - 1) % 3);

        const station = line.stations[station_ind];
        try station.pollX(io);

        switch (side) {
            .backward => {
                if (station.x.hall_alarm.axis(local_axis).back != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
            .forward => {
                if (station.x.hall_alarm.axis(local_axis).front != alarm_on) {
                    return error.UnexpectedHallAlarm;
                }
            },
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
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

    const station_ind: mcl.Station.Index = @intCast((axis - 1) / 3);
    const local_axis: mcl.Axis.Index.Station = @intCast((axis - 1) % 3);

    const station = line.stations[station_ind];
    try station.pollX();

    switch (side) {
        .backward => {
            if (station.x.hall_alarm.axis(local_axis).back != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
        .forward => {
            if (station.x.hall_alarm.axis(local_axis).front != alarm_on) {
                return error.UnexpectedHallAlarm;
            }
        },
    }
}

fn mclSliderPosMoveAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
                (aux.index.line < main.index.line and axis_id <= aux.id.line))
            {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |aux| {
            // Direction of auxiliary axis from main axis.
            var direction: Direction = undefined;
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderToAxisByPosition,
            .command_slider_number = slider_id,
            .target_axis_number = axis_id,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line))
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisByPosition,
        .command_slider_number = slider_id,
        .target_axis_number = axis_id,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPosMoveLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;
        var direction: Direction = undefined;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            // Direction of auxiliary axis from main axis.
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }

            const current_location =
                main.station.wr.slider_location.axis(main.index.station).toFloat();
            if ((direction == .forward and location_float > current_location) or
                (direction == .backward and location_float < current_location))
            {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderToLocationByPosition,
            .command_slider_number = slider_id,
            .location_distance = location,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }

        const current_location =
            main.station.wr.slider_location.axis(main.index.station).toFloat();
        if ((direction == .forward and location_float > current_location) or
            (direction == .backward and location_float < current_location))
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationByPosition,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPosMoveDistance(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const move_direction: Direction = move_dir: {
        if (distance_float > 0.0) {
            break :move_dir .forward;
        } else if (distance_float < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const distance: Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;

        if (_aux) |aux| {
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            // Set command station in direction of movement command.
            if (move_direction == direction) {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderDistanceByPosition,
            .command_slider_number = slider_id,
            .location_distance = distance,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceByPosition,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderSpdMoveAxis(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
                (aux.index.line < main.index.line and axis_id <= aux.id.line))
            {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |aux| {
            // Direction of auxiliary axis from main axis.
            var direction: Direction = undefined;
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderToAxisBySpeed,
            .command_slider_number = slider_id,
            .target_axis_number = axis_id,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line))
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToAxisBySpeed,
        .command_slider_number = slider_id,
        .target_axis_number = axis_id,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderSpdMoveLocation(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const location_float: f32 = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;
        var direction: Direction = undefined;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            // Direction of auxiliary axis from main axis.
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }

            const current_location =
                main.station.wr.slider_location.axis(main.index.station).toFloat();
            if ((direction == .forward and location_float > current_location) or
                (direction == .backward and location_float < current_location))
            {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderToLocationBySpeed,
            .command_slider_number = slider_id,
            .location_distance = location,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_speeds[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }

        const current_location =
            main.station.wr.slider_location.axis(main.index.station).toFloat();
        if ((direction == .forward and location_float > current_location) or
            (direction == .backward and location_float < current_location))
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderToLocationBySpeed,
        .command_slider_number = slider_id,
        .location_distance = location,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_speeds[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderSpdMoveDistance(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    const distance_float = try std.fmt.parseFloat(f32, params[2]);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const move_direction: Direction = move_dir: {
        if (distance_float > 0.0) {
            break :move_dir .forward;
        } else if (distance_float < 0.0) {
            break :move_dir .backward;
        } else {
            return;
        }
    };

    const distance: Distance = .{
        .mm = @intFromFloat(distance_float),
        .um = @intFromFloat((distance_float - @trunc(distance_float)) * 1000),
    };

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;

        if (_aux) |aux| {
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            // Set command station in direction of movement command.
            if (move_direction == direction) {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderDistanceBySpeed,
            .command_slider_number = slider_id,
            .location_distance = distance,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        // Set command station in direction of movement command.
        if (move_direction == direction) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderDistanceBySpeed,
        .command_slider_number = slider_id,
        .location_distance = distance,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPushForward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            if (direction == .forward) {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .PushAxisSliderForward,
            .command_slider_number = slider_id,
            .target_axis_number = main.index.station + 1,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;
    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        if (direction == .forward) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderForward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPushBackward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            if (direction == .backward) {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |_| {
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .PushAxisSliderBackward,
            .command_slider_number = slider_id,
            .target_axis_number = main.index.station + 1,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Direction of auxiliary axis from main axis.
    var direction: Direction = undefined;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        if (direction == .backward) {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |_| {
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .PushAxisSliderBackward,
        .command_slider_number = slider_id,
        .target_axis_number = main.index.station + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPullForward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const slider_id = try std.fmt.parseInt(u16, params[2], 0);
    const location_float = try std.fmt.parseFloat(f32, params[3]);
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        const location: Distance = .{
            .mm = @intFromFloat(location_float),
            .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
        };

        if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
        const station = line.stations[axis_index / 3];

        try waitCommandReady(io, line_idx, station.index);
        station.ww.* = .{
            .command_code = .PullAxisSliderForward,
            .location_distance = location,
            .command_slider_number = slider_id,
            .target_axis_number = local_axis + 1,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(io, line_idx, station.index);
    station.ww.* = .{
        .command_code = .PullAxisSliderForward,
        .location_distance = location,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderPullBackward(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(u16, params[1], 0);
    const slider_id = try std.fmt.parseInt(u16, params[2], 0);
    const location_float = try std.fmt.parseFloat(f32, params[3]);
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        const location: Distance = .{
            .mm = @intFromFloat(location_float),
            .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
        };

        if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
        const station = line.stations[axis_index / 3];

        try waitCommandReady(io, line_idx, station.index);
        station.ww.* = .{
            .command_code = .PullAxisSliderBackward,
            .location_distance = location,
            .command_slider_number = slider_id,
            .target_axis_number = local_axis + 1,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    const location: Distance = .{
        .mm = @intFromFloat(location_float),
        .um = @intFromFloat((location_float - @trunc(location_float)) * 1000),
    };

    if (axis == 0 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try waitCommandReady(io, line_idx, station.index);
    station.ww.* = .{
        .command_code = .PullAxisSliderBackward,
        .location_distance = location,
        .command_slider_number = slider_id,
        .target_axis_number = local_axis + 1,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclSliderWaitPull(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(i16, params[1], 0);
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
        const station = line.stations[axis_index / 3];

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            try station.pollWr(io);
            const slider_state = station.wr.slider_state.axis(local_axis);
            if (slider_state == .PullForwardCompleted or
                slider_state == .PullBackwardCompleted) break;
            if (slider_state == .PullForwardFault or
                slider_state == .PullBackwardFault)
                return error.SliderPullError;
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        try station.pollWr();
        const slider_state = station.wr.slider_state.axis(local_axis);
        if (slider_state == .PullForwardCompleted or
            slider_state == .PullBackwardCompleted) break;
        if (slider_state == .PullForwardFault or
            slider_state == .PullBackwardFault)
            return error.SliderPullError;
    }
}

fn mclSliderStopPull(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name = params[0];
    const axis = try std.fmt.parseInt(i16, params[1], 0);
    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
        const station = line.stations[axis_index / 3];
        station.y.reset_pull_slider.setAxis(local_axis, true);
        try station.sendY(io);
        defer {
            station.y.reset_pull_slider.setAxis(local_axis, false);
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            if (!station.x.pulling_slider.axis(local_axis)) break;
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis < 1 or axis > line.axes.len) return error.InvalidAxis;

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    try station.setY(0x10 + @as(u6, local_axis));
    defer station.resetY(0x10 + @as(u6, local_axis)) catch {};

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();
        if (!station.x.pulling_slider.axis(local_axis)) break;
    }
}

fn mclWaitMoveSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id = try std.fmt.parseInt(u16, params[1], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        while (true) {
            try command.checkCommandInterrupt();
            try line.pollWr(io);
            const main, _ = if (line.search(slider_id)) |t| t
                // Do not error here as the poll receiving CC-Link information can
                // "move past" a backwards traveling slider during transmission, thus
                // rendering the slider briefly invisible in the whole loop.
                else continue;
            const station = main.station.*;
            const wr = station.wr;

            if (wr.slider_state.axis(main.index.station) == .PosMoveCompleted or
                wr.slider_state.axis(main.index.station) == .SpdMoveCompleted or
                wr.slider_state.axis(main.index.station) == .ChainCompleted or
                wr.slider_state.axis(main.index.station) == .ChainSlaveCompleted)
            {
                break;
            }

            if (main.id.line < line.axes.len) {
                const next_axis_index = @rem(main.index.station + 1, 3);
                const next_station = if (next_axis_index == 0)
                    line.stations[station.index + 1]
                else
                    station;
                const slider_number =
                    next_station.wr.slider_number.axis(next_axis_index);
                const slider_state =
                    next_station.wr.slider_state.axis(next_axis_index);
                if (slider_number == slider_id and
                    (slider_state == .PosMoveCompleted or
                        slider_state == .SpdMoveCompleted or
                        slider_state == .ChainCompleted or
                        slider_state == .ChainSlaveCompleted))
                {
                    break;
                }
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    while (true) {
        try command.checkCommandInterrupt();
        try line.pollWr();
        const main, _ = if (line.search(slider_id)) |t| t
            // Do not error here as the poll receiving CC-Link information can
            // "move past" a backwards traveling slider during transmission, thus
            // rendering the slider briefly invisible in the whole loop.
            else continue;
        const station = main.station.*;
        const wr = station.wr;

        if (wr.slider_state.axis(main.index.station) == .PosMoveCompleted or
            wr.slider_state.axis(main.index.station) == .SpdMoveCompleted or
            wr.slider_state.axis(main.index.station) == .ChainCompleted or
            wr.slider_state.axis(main.index.station) == .ChainSlaveCompleted)
        {
            break;
        }

        if (main.id.line < line.axes.len) {
            const next_axis_index = @rem(main.index.station + 1, 3);
            const next_station = if (next_axis_index == 0)
                line.stations[station.index + 1]
            else
                station;
            const slider_number =
                next_station.wr.slider_number.axis(next_axis_index);
            const slider_state =
                next_station.wr.slider_state.axis(next_axis_index);
            if (slider_number == slider_id and
                (slider_state == .PosMoveCompleted or
                    slider_state == .SpdMoveCompleted or
                    slider_state == .ChainCompleted or
                    slider_state == .ChainSlaveCompleted))
            {
                break;
            }
        }
    }
}

fn mclRecoverSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: u16 = try std.fmt.parseUnsigned(u16, params[1], 0);
    const new_slider_id: u16 = try std.fmt.parseUnsigned(u16, params[2], 0);
    if (new_slider_id == 0 or new_slider_id > 254)
        return error.InvalidSliderID;
    const sensor: []const u8 = params[3];

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis < 1 or axis > line.axes.len) {
            return error.InvalidAxis;
        }

        const use_sensor: ?Direction = parse_use_sensor: {
            if (sensor.len == 0) break :parse_use_sensor null;
            if (std.ascii.eqlIgnoreCase("back", sensor) or
                std.ascii.eqlIgnoreCase("left", sensor))
            {
                break :parse_use_sensor .backward;
            } else if (std.ascii.eqlIgnoreCase("front", sensor) or
                std.ascii.eqlIgnoreCase("right", sensor))
            {
                break :parse_use_sensor .forward;
            } else return error.InvalidSensorSide;
        };

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

        const station = line.stations[axis_index / 3];
        try waitCommandReady(io, line_idx, station.index);
        if (use_sensor) |side| {
            if (side == .backward) {
                station.y.recovery_use_hall_sensor.back = true;
            } else {
                station.y.recovery_use_hall_sensor.front = true;
            }
            try station.sendY(io);
        }
        defer {
            if (use_sensor) |side| {
                if (side == .backward) {
                    station.y.recovery_use_hall_sensor.back = false;
                } else {
                    station.y.recovery_use_hall_sensor.front = false;
                }
                station.sendY(io) catch {};
            }
        }
        station.ww.* = .{
            .command_code = .RecoverSliderAtAxis,
            .target_axis_number = local_axis_index + 1,
            .command_slider_number = new_slider_id,
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis < 1 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const use_sensor: ?Direction = parse_use_sensor: {
        if (sensor.len == 0) break :parse_use_sensor null;
        if (std.ascii.eqlIgnoreCase("back", sensor) or
            std.ascii.eqlIgnoreCase("left", sensor))
        {
            break :parse_use_sensor .backward;
        } else if (std.ascii.eqlIgnoreCase("front", sensor) or
            std.ascii.eqlIgnoreCase("right", sensor))
        {
            break :parse_use_sensor .forward;
        } else return error.InvalidSensorSide;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);

    const station = line.stations[axis_index / 3];
    try waitCommandReady(io, line_idx, station.index);
    if (use_sensor) |side| {
        if (side == .backward) {
            try station.setY(0x13);
            station.y.recovery_use_hall_sensor.back = true;
        } else {
            try station.setY(0x14);
            station.y.recovery_use_hall_sensor.front = true;
        }
    }
    defer {
        if (use_sensor) |side| {
            if (side == .backward) {
                if (station.resetY(0x13)) {
                    station.y.recovery_use_hall_sensor.back = false;
                } else |_| {}
            } else {
                if (station.resetY(0x14)) {
                    station.y.recovery_use_hall_sensor.front = false;
                } else |_| {}
            }
        }
    }
    station.ww.* = .{
        .command_code = .RecoverSliderAtAxis,
        .target_axis_number = local_axis_index + 1,
        .command_slider_number = new_slider_id,
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclTrafficStop(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis == 0 or axis > line.axes.len) {
            return error.InvalidAxis;
        }

        const direction: Direction = dir: {
            if (std.ascii.eqlIgnoreCase("next", params[2]) or
                std.ascii.eqlIgnoreCase("right", params[2]))
            {
                break :dir .forward;
            } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
                std.ascii.eqlIgnoreCase("left", params[2]))
            {
                break :dir .backward;
            } else return error.InvalidDirection;
        };

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const station = line.stations[axis_index / 3];
        try station.poll(io);

        station.y.stop_driver_transmission.setTo(direction, true);
        try station.sendY(io);
        while (!station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const direction: Direction = dir: {
        if (std.ascii.eqlIgnoreCase("next", params[2]) or
            std.ascii.eqlIgnoreCase("right", params[2]))
        {
            break :dir .forward;
        } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
            std.ascii.eqlIgnoreCase("left", params[2]))
        {
            break :dir .backward;
        } else return error.InvalidDirection;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const station = line.stations[axis_index / 3];
    try station.poll();

    station.y.stop_driver_transmission.setTo(direction, true);
    try station.sendY();
    while (!station.x.transmission_stopped.to(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX();
    }
}

fn mclTrafficAllow(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis = try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis == 0 or axis > line.axes.len) {
            return error.InvalidAxis;
        }

        const direction: Direction = dir: {
            if (std.ascii.eqlIgnoreCase("next", params[2]) or
                std.ascii.eqlIgnoreCase("right", params[2]))
            {
                break :dir .forward;
            } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
                std.ascii.eqlIgnoreCase("left", params[2]))
            {
                break :dir .backward;
            } else return error.InvalidDirection;
        };

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const station = line.stations[axis_index / 3];
        try station.poll(io);

        station.y.stop_driver_transmission.setTo(direction, false);
        try station.sendY(io);
        while (station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const direction: Direction = dir: {
        if (std.ascii.eqlIgnoreCase("next", params[2]) or
            std.ascii.eqlIgnoreCase("right", params[2]))
        {
            break :dir .forward;
        } else if (std.ascii.eqlIgnoreCase("prev", params[2]) or
            std.ascii.eqlIgnoreCase("left", params[2]))
        {
            break :dir .backward;
        } else return error.InvalidDirection;
    };

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const station = line.stations[axis_index / 3];
    try station.poll();

    station.y.stop_driver_transmission.setTo(direction, false);
    try station.sendY();
    while (station.x.transmission_stopped.to(direction)) {
        try command.checkCommandInterrupt();
        try station.pollX();
    }
}

fn mclWaitRecoverSlider(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis: u16 = try std.fmt.parseUnsigned(u16, params[1], 0);
    const result_var: []const u8 = params[2];

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis == 0 or axis > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
        const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
        const station = line.stations[axis_index / 3];

        var slider_id: u16 = undefined;
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollWr(io);

            const slider_number = station.wr.slider_number.axis(local_axis_index);
            if (slider_number != 0 and station.wr.slider_state.axis(
                local_axis_index,
            ) == .PosMoveCompleted) {
                slider_id = slider_number;
                break;
            }
        }

        std.log.info("Slider {d} recovered.\n", .{slider_id});
        if (result_var.len > 0) {
            var int_buf: [8]u8 = undefined;
            try command.variables.put(
                result_var,
                try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
            );
        }
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis == 0 or axis > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis_index: mcl.Axis.Index.Line = @intCast(axis - 1);
    const local_axis_index: mcl.Axis.Index.Station = @intCast(axis_index % 3);
    const station = line.stations[axis_index / 3];

    var slider_id: u16 = undefined;
    while (true) {
        try command.checkCommandInterrupt();
        try station.pollWr();

        const slider_number = station.wr.slider_number.axis(local_axis_index);
        if (slider_number != 0 and station.wr.slider_state.axis(
            local_axis_index,
        ) == .PosMoveCompleted) {
            slider_id = slider_number;
            break;
        }
    }

    std.log.info("Slider {d} recovered.\n", .{slider_id});
    if (result_var.len > 0) {
        var int_buf: [8]u8 = undefined;
        try command.variables.put(
            result_var,
            try std.fmt.bufPrint(&int_buf, "{d}", .{slider_id}),
        );
    }
}

fn mclSliderChainLink(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const first_axis: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);
    const second_axis: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[2], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (first_axis == 0 or first_axis > line.axes.len) {
            return error.InvalidAxis;
        }
        if (second_axis == 0 or second_axis > line.axes.len) {
            return error.InvalidAxis;
        }

        if (@abs(first_axis - second_axis) != 1) {
            return error.InvalidAxisPair;
        }

        const axis = line.axes[first_axis - 1];
        const axis_two = line.axes[second_axis - 1];
        const station = line.axes[first_axis - 1].station;
        const station_two = axis_two.station;
        try station.pollWr(io);
        try station_two.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }
        if (station_two.wr.slider_number.axis(axis_two.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        if (second_axis > first_axis) {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .forward = true },
            );
        } else {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .backward = true },
            );
        }
        try station.sendY(io);
        defer {
            if (second_axis > first_axis) {
                station.y.link_chain.setAxis(
                    axis.index.station,
                    .{ .forward = false },
                );
            } else {
                station.y.link_chain.setAxis(
                    axis.index.station,
                    .{ .backward = false },
                );
            }
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (second_axis > first_axis and
                station.x.chain_enabled.axis(axis.index.station).forward)
            {
                break;
            } else if (second_axis < first_axis and
                station.x.chain_enabled.axis(axis.index.station).backward)
            {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (first_axis == 0 or first_axis > line.axes.len) {
        return error.InvalidAxis;
    }
    if (second_axis == 0 or second_axis > line.axes.len) {
        return error.InvalidAxis;
    }

    if (@abs(first_axis - second_axis) != 1) {
        return error.InvalidAxisPair;
    }

    const axis = line.axes[first_axis - 1];
    const axis_two = line.axes[second_axis - 1];
    const station = line.axes[first_axis - 1].station;
    const station_two = axis_two.station;
    try station.pollWr();
    try station_two.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }
    if (station_two.wr.slider_number.axis(axis_two.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    if (second_axis > first_axis) {
        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .forward = true },
        );
    } else {
        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .backward = true },
        );
    }
    try station.sendY();
    defer {
        if (second_axis > first_axis) {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .forward = false },
            );
        } else {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .backward = false },
            );
        }
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (second_axis > first_axis and
            station.x.chain_enabled.axis(axis.index.station).forward)
        {
            break;
        } else if (second_axis < first_axis and
            station.x.chain_enabled.axis(axis.index.station).backward)
        {
            break;
        }
    }
}

fn mclSliderChainUnlink(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const first_axis: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);
    const second_axis: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[2], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (first_axis == 0 or first_axis > line.axes.len) {
            return error.InvalidAxis;
        }
        if (second_axis == 0 or second_axis > line.axes.len) {
            return error.InvalidAxis;
        }

        if (@abs(first_axis - second_axis) != 1) {
            return error.InvalidAxisPair;
        }

        const axis = line.axes[first_axis - 1];
        const axis_two = line.axes[second_axis - 1];
        const station = line.axes[first_axis - 1].station;
        const station_two = axis_two.station;
        try station.pollWr(io);
        try station_two.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }
        if (station_two.wr.slider_number.axis(axis_two.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        if (second_axis > first_axis) {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .forward = true },
            );
        } else {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .backward = true },
            );
        }
        try station.sendY(io);
        defer {
            if (second_axis > first_axis) {
                station.y.unlink_chain.setAxis(
                    axis.index.station,
                    .{ .forward = false },
                );
            } else {
                station.y.unlink_chain.setAxis(
                    axis.index.station,
                    .{ .backward = false },
                );
            }
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (second_axis > first_axis and
                !station.x.chain_enabled.axis(axis.index.station).forward)
            {
                break;
            } else if (second_axis < first_axis and
                !station.x.chain_enabled.axis(axis.index.station).backward)
            {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (first_axis == 0 or first_axis > line.axes.len) {
        return error.InvalidAxis;
    }
    if (second_axis == 0 or second_axis > line.axes.len) {
        return error.InvalidAxis;
    }

    if (@abs(first_axis - second_axis) != 1) {
        return error.InvalidAxisPair;
    }

    const axis = line.axes[first_axis - 1];
    const axis_two = line.axes[second_axis - 1];
    const station = line.axes[first_axis - 1].station;
    const station_two = axis_two.station;
    try station.pollWr();
    try station_two.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }
    if (station_two.wr.slider_number.axis(axis_two.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    if (second_axis > first_axis) {
        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .forward = true },
        );
    } else {
        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .backward = true },
        );
    }
    try station.sendY();
    defer {
        if (second_axis > first_axis) {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .forward = false },
            );
        } else {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .backward = false },
            );
        }
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (second_axis > first_axis and
            !station.x.chain_enabled.axis(axis.index.station).forward)
        {
            break;
        } else if (second_axis < first_axis and
            !station.x.chain_enabled.axis(axis.index.station).backward)
        {
            break;
        }
    }
}

fn mclSetLeftChainOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        try station.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .backward = true },
        );
        try station.sendY(io);
        defer {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .backward = false },
            );
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (station.x.chain_enabled.axis(axis.index.station).backward) {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[@intCast(axis_id - 1)];
    const station = axis.station;
    try station.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    station.y.link_chain.setAxis(
        axis.index.station,
        .{ .backward = true },
    );
    try station.sendY();
    defer {
        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .backward = false },
        );
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (station.x.chain_enabled.axis(axis.index.station).backward) {
            break;
        }
    }
}

fn mclSetRightChainOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        try station.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .forward = true },
        );
        try station.sendY(io);
        defer {
            station.y.link_chain.setAxis(
                axis.index.station,
                .{ .forward = false },
            );
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (station.x.chain_enabled.axis(axis.index.station).forward) {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[@intCast(axis_id - 1)];
    const station = axis.station;
    try station.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    station.y.link_chain.setAxis(
        axis.index.station,
        .{ .forward = true },
    );
    try station.sendY();
    defer {
        station.y.link_chain.setAxis(
            axis.index.station,
            .{ .forward = false },
        );
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (station.x.chain_enabled.axis(axis.index.station).forward) {
            break;
        }
    }
}

fn mclSetLeftChainOff(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        try station.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .backward = true },
        );
        try station.sendY(io);
        defer {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .backward = false },
            );
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (!station.x.chain_enabled.axis(axis.index.station).backward) {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[@intCast(axis_id - 1)];
    const station = axis.station;
    try station.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    station.y.unlink_chain.setAxis(
        axis.index.station,
        .{ .backward = true },
    );
    try station.sendY();
    defer {
        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .backward = false },
        );
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (!station.x.chain_enabled.axis(axis.index.station).backward) {
            break;
        }
    }
}

fn mclSetRightChainOff(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const axis_id: mcl.Axis.Id.Line =
        try std.fmt.parseUnsigned(mcl.Axis.Id.Line, params[1], 0);

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];

        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        const axis = line.axes[@intCast(axis_id - 1)];
        const station = axis.station;
        try station.pollWr(io);

        if (station.wr.slider_number.axis(axis.index.station) == 0) {
            return error.NoSliderOnAxis;
        }

        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .forward = true },
        );
        try station.sendY(io);
        defer {
            station.y.unlink_chain.setAxis(
                axis.index.station,
                .{ .forward = false },
            );
            station.sendY(io) catch {};
        }

        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);

            if (!station.x.chain_enabled.axis(axis.index.station).forward) {
                break;
            }
        }
        return;
    }
    const line = mcl.lines[line_idx];

    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    const axis = line.axes[@intCast(axis_id - 1)];
    const station = axis.station;
    try station.pollWr();

    if (station.wr.slider_number.axis(axis.index.station) == 0) {
        return error.NoSliderOnAxis;
    }

    station.y.unlink_chain.setAxis(
        axis.index.station,
        .{ .forward = true },
    );
    try station.sendY();
    defer {
        station.y.unlink_chain.setAxis(
            axis.index.station,
            .{ .forward = false },
        );
        station.sendY() catch {};
    }

    while (true) {
        try command.checkCommandInterrupt();
        try station.pollX();

        if (!station.x.chain_enabled.axis(axis.index.station).forward) {
            break;
        }
    }
}

fn mclMoveSliderChain(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const line_name: []const u8 = params[0];
    const slider_id: u16 = try std.fmt.parseInt(u16, params[1], 0);
    const axis_id: u16 = try std.fmt.parseInt(u16, params[2], 0);
    if (slider_id == 0 or slider_id > 254) return error.InvalidSliderId;

    const line_idx = try matchLine(line_names, line_name);
    if (ethercat) |*eth| {
        const line = eth.lines[line_idx];
        if (axis_id == 0 or axis_id > line.axes.len) {
            return error.InvalidAxis;
        }

        try line.pollWr(io);
        const main, const _aux =
            if (line.search(slider_id)) |t| t else return error.SliderNotFound;
        var station = main.station.*;

        // Set command station in direction of movement command.
        if (_aux) |aux| {
            if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
                (aux.index.line < main.index.line and axis_id <= aux.id.line))
            {
                station = aux.station.*;
            }
        }

        try waitCommandReady(io, line_idx, station.index);

        if (_aux) |aux| {
            // Direction of auxiliary axis from main axis.
            var direction: Direction = undefined;
            if (aux.index.line > main.index.line) {
                direction = .forward;
            } else {
                direction = .backward;
            }
            main.station.y.stop_driver_transmission.setTo(direction, true);
            try main.station.sendY(io);
            defer {
                main.station.y.stop_driver_transmission.setTo(direction, false);
                main.station.sendY(io) catch {};
            }
            while (!main.station.x.transmission_stopped.to(direction)) {
                try command.checkCommandInterrupt();
                try main.station.pollX(io);
            }
        }

        station.ww.* = .{
            .command_code = .MoveSliderChain,
            .command_slider_number = slider_id,
            .target_axis_number = axis_id,
            .speed_percentage = line_speeds[line_idx],
            .acceleration_percentage = line_accelerations[line_idx],
        };
        try sendCommand(io, line_idx, station.index);
        return;
    }
    const line = mcl.lines[line_idx];
    if (axis_id == 0 or axis_id > line.axes.len) {
        return error.InvalidAxis;
    }

    try line.pollWr();
    const main, const _aux =
        if (line.search(slider_id)) |t| t else return error.SliderNotFound;
    var station: mcl.Station = main.station.*;

    // Set command station in direction of movement command.
    if (_aux) |aux| {
        if ((main.index.line < aux.index.line and axis_id >= aux.id.line) or
            (aux.index.line < main.index.line and axis_id <= aux.id.line))
        {
            station = aux.station.*;
        }
    }

    try waitCommandReady(io, line_idx, station.index);

    if (_aux) |aux| {
        // Direction of auxiliary axis from main axis.
        var direction: Direction = undefined;
        if (aux.index.line > main.index.line) {
            direction = .forward;
        } else {
            direction = .backward;
        }
        main.station.y.stop_driver_transmission.setTo(direction, true);
        try main.station.sendY();
        defer {
            main.station.y.stop_driver_transmission.setTo(direction, false);
            main.station.sendY() catch {};
        }
        while (!main.station.x.transmission_stopped.to(direction)) {
            try command.checkCommandInterrupt();
            try main.station.pollX();
        }
    }

    station.ww.* = .{
        .command_code = .MoveSliderChain,
        .command_slider_number = slider_id,
        .target_axis_number = axis_id,
        .speed_percentage = line_speeds[line_idx],
        .acceleration_percentage = line_accelerations[line_idx],
    };
    try sendCommand(io, line_idx, station.index);
}

fn mclStopOn(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line_idx = try matchLine(line_names, line_name);
        if (ethercat) |*eth| {
            const line = eth.lines[line_idx];
            // Enable emergency stop for all drivers on the line
            for (line.stations) |station| {
                station.y.emergency_stop = true;
                try station.sendY(io);
            }
            // Wait until all drivers is stopped
            wait_stop: while (true) {
                try command.checkCommandInterrupt();
                for (line.stations) |station| {
                    try station.pollX(io);
                    if (!station.x.emergency_stop_enabled) continue :wait_stop;
                }
                return;
            }
        }
        const line = mcl.lines[line_idx];
        // Enable emergency stop for all drivers on the line
        for (line.stations) |station| {
            try station.setY(0x7);
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX();
                if (!station.x.emergency_stop_enabled) continue :wait_stop;
            }
            return;
        }
    } else {
        if (ethercat) |*eth| {
            // Enable emergency stop for all drivers
            for (eth.lines) |line| {
                for (line.stations) |station| {
                    station.y.emergency_stop = true;
                    try station.sendY(io);
                }
            }
            // Wait until all drivers is stopped
            wait_stop: while (true) {
                try command.checkCommandInterrupt();
                for (eth.lines) |line| {
                    for (line.stations) |station| {
                        try station.pollX(io);
                        if (!station.x.emergency_stop_enabled) continue :wait_stop;
                    }
                }
                return;
            }
        }
        // Enable emergency stop for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.setY(0x7);
            }
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX();
                    if (!station.x.emergency_stop_enabled) continue :wait_stop;
                }
            }
            return;
        }
    }
}

fn mclStopOff(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line_idx = try matchLine(line_names, line_name);
        const line = mcl.lines[line_idx];
        // Enable emergency stop for all drivers on the line
        for (line.stations) |station| {
            try station.resetY(0x7);
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX();
                if (station.x.emergency_stop_enabled) continue :wait_stop;
            }
            return;
        }
    } else {
        // Enable emergency stop for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.resetY(0x7);
            }
        }
        // Wait until all drivers is stopped
        wait_stop: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX();
                    if (station.x.emergency_stop_enabled) continue :wait_stop;
                }
            }
            return;
        }
    }
}

fn mclPauseOn(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line_idx = try matchLine(line_names, line_name);
        const line = mcl.lines[line_idx];
        // Enable temporary pause for all drivers on the line
        for (line.stations) |station| {
            try station.setY(0x8);
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX();
                if (!station.x.paused) continue :wait_pause;
            }
            return;
        }
    } else {
        // Enable temporary pause for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.setY(0x8);
            }
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX();
                    if (!station.x.paused) continue :wait_pause;
                }
            }
            return;
        }
    }
}

fn mclPauseOff(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len != 0) {
        const line_name: []const u8 = params[0];
        const line_idx = try matchLine(line_names, line_name);
        const line = mcl.lines[line_idx];
        // Enable temporary pause for all drivers on the line
        for (line.stations) |station| {
            try station.resetY(0x8);
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (line.stations) |station| {
                try station.pollX();
                if (station.x.paused) continue :wait_pause;
            }
            return;
        }
    } else {
        // Enable temporary pause for all drivers
        for (mcl.lines) |line| {
            for (line.stations) |station| {
                try station.resetY(0x8);
            }
        }
        // Wait until all drivers is paused
        wait_pause: while (true) {
            try command.checkCommandInterrupt();
            for (mcl.lines) |line| {
                for (line.stations) |station| {
                    try station.pollX();
                    if (station.x.paused) continue :wait_pause;
                }
            }
            return;
        }
    }
}

fn matchLine(names: []const []const u8, name: []const u8) !mcl.Line.Index {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    } else {
        return error.LineNameNotFound;
    }
}

fn waitCommandReady(
    io: std.Io,
    line_idx: mcl.Line.Index,
    station_idx: mcl.Station.Index,
) !void {
    std.log.debug("Waiting for command ready state...", .{});
    if (ethercat) |*eth| {
        const station = eth.lines[line_idx].stations[station_idx];
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX(io);
            if (station.x.ready_for_command) break;
        }
    } else {
        const station = mcl.lines[line_idx].stations[station_idx];
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX();
            if (station.x.ready_for_command) break;
        }
    }
}

fn sendCommand(
    io: std.Io,
    line_idx: mcl.Line.Index,
    station_idx: mcl.Station.Index,
) !void {
    std.log.debug("Sending command...", .{});
    var command_response: mcl.registers.Wr.CommandResponseCode = .NoError;
    if (ethercat) |*eth| {
        const station = eth.lines[line_idx].stations[station_idx];
        {
            station.y.start_command = true;
            try station.send(io);
            defer {
                station.y.start_command = false;
                station.send(io) catch {};
            }
            while (true) {
                try command.checkCommandInterrupt();
                try station.pollX(io);
                if (station.x.command_received) {
                    break;
                }
            }
        }
        try station.pollWr(io);
        command_response = station.wr.command_response;
        {
            std.log.debug("Resetting command received flag...", .{});
            station.y.reset_command_received = true;
            try station.sendY(io);
            defer {
                station.y.reset_command_received = false;
                station.sendY(io) catch {};
            }
            while (true) {
                try command.checkCommandInterrupt();
                try station.pollX(io);
                if (!station.x.command_received) {
                    break;
                }
            }
        }
    } else {
        const station = mcl.lines[line_idx].stations[station_idx];
        try station.sendWw();
        try station.setY(0x2);
        errdefer station.resetY(0x2) catch {};
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX();
            if (station.x.command_received) {
                break;
            }
        }
        try station.resetY(0x2);

        try station.pollWr();
        command_response = station.wr.command_response;

        std.log.debug("Resetting command received flag...", .{});
        try station.setY(0x3);
        errdefer station.resetY(0x3) catch {};
        while (true) {
            try command.checkCommandInterrupt();
            try station.pollX();
            if (!station.x.command_received) {
                try station.resetY(0x3);
                break;
            }
        }
    }

    return switch (command_response) {
        .NoError => {},
        .InvalidCommand => error.InvalidCommand,
        .SliderNotFound => error.SliderNotFound,
        .HomingFailed => error.HomingFailed,
        .InvalidParameter => error.InvalidParameter,
        .InvalidSystemState => error.InvalidSystemState,
        .SliderAlreadyExists => error.SliderAlreadyExists,
        .InvalidAxis => error.InvalidAxis,
    };
}

test {
    std.testing.refAllDecls(@This());
}
