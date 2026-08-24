const std = @import("std");
pub const soem = @import("soem");
const registers = @import("../Mcl.zig").registers;
const protocol = @import("../protocol.zig");
pub const Board = @import("ethercat/Ethercat.zig");

const X = registers.X;
const Y = registers.Y;
const Wr = registers.Wr;
const Ww = registers.Ww;
pub const Id = std.math.IntFittingRange(1, 256);
master: Board,
/// List of all initialized slaves
slaves: []soem.ec_slavet,

pub const Config = struct {
    /// Station ID on the channel
    station_id: std.math.IntFittingRange(1, 256),
    /// Number of axes used on the station
    axes: u2,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    var res: @This() = undefined;
    res.master = try .init(gpa, io);
    const slaves: usize = @intCast(res.master.ctx.slavecount);
    res.slaves = res.master.ctx.slavelist[0 .. slaves + 1];
    return res;
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.master.deinit(gpa);
    self.slaves = &.{};
}

pub const Station = struct {
    slave: *soem.ec_slavet,
    lock: *std.Io.RwLock,

    pub const Config = struct {
        /// Station ID on the channel
        station_id: Id,
        /// Number of axes used on the station
        axes: u2,
    };

    pub fn setY(
        self: Station,
        io: std.Io,
        /// Bitwise offset of desired field (0..).
        offset: u6,
    ) !void {
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        var y: u64 =
            @bitCast(self.slave.outputs[0..@sizeOf(Y)].*);
        // Turn on bit in Y on the offset index
        y |= @as(u64, 1) << offset;
        @memcpy(
            self.slave.outputs[0..@sizeOf(Y)],
            std.mem.asBytes(&y),
        );
    }

    pub fn resetY(
        self: Station,
        io: std.Io,
        /// Bitwise offset of desired field (0..).
        offset: u6,
    ) !void {
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        var y: u64 =
            @bitCast(self.slave.outputs[0..@sizeOf(Y)].*);
        // Turn off bit in Y on the offset index
        y &= ~(@as(u64, 1) << offset);
        @memcpy(
            self.slave.outputs[0..@sizeOf(Y)],
            std.mem.asBytes(&y),
        );
    }

    pub fn pollX(self: Station, io: std.Io, x: *X) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        @memcpy(
            std.mem.asBytes(x),
            self.slave.inputs[0..@sizeOf(X)],
        );
    }

    pub fn pollWr(self: Station, io: std.Io, wr: *Wr) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        @memcpy(
            std.mem.asBytes(wr),
            self.slave.inputs[@sizeOf(X) .. @sizeOf(X) + @sizeOf(Wr)],
        );
    }

    pub fn pollY(self: Station, io: std.Io, y: *Y) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        @memcpy(
            std.mem.asBytes(y),
            self.slave.outputs[0..@sizeOf(Y)],
        );
    }

    pub fn pollWw(self: Station, io: std.Io, ww: *Ww) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        @memcpy(
            std.mem.asBytes(ww),
            self.slave.outputs[@sizeOf(Y) .. @sizeOf(Y) + @sizeOf(Ww)],
        );
    }

    pub fn sendY(self: Station, io: std.Io, y: *Y) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        @memcpy(
            self.slave.outputs[0..@sizeOf(Y)],
            std.mem.asBytes(y),
        );
    }

    pub fn sendWw(self: Station, io: std.Io, ww: *Ww) !void {
        // Ensure slave still in operational mode
        if (self.slave.state != soem.EC_STATE_OPERATIONAL) {
            return error.SlaveNotOperational;
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        @memcpy(
            self.slave.outputs[@sizeOf(Y) .. @sizeOf(Y) + @sizeOf(Ww)],
            std.mem.asBytes(ww),
        );
    }
};

pub const Line = struct {
    /// Slaves of a line
    slaves: []soem.ec_slavet,
    lock: *std.Io.RwLock,

    pub fn init(
        slaves: []soem.ec_slavet,
        lock: *std.Io.RwLock,
        drivers: []protocol.Config,
    ) Line {
        const start = drivers[0].ethercat.station_id;
        const end = drivers[drivers.len - 1].ethercat.station_id + 1;
        return .{
            .slaves = slaves[start..end],
            .lock = lock,
        };
    }

    pub fn pollX(self: Line, io: std.Io, x: []X) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        for (self.slaves, x) |slave, *x_station| {
            @memcpy(
                std.mem.asBytes(x_station),
                slave.inputs[0..@sizeOf(X)],
            );
        }
    }

    pub fn pollY(self: Line, io: std.Io, y: []Y) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        for (self.slaves, y) |slave, *y_station| {
            @memcpy(
                std.mem.asBytes(y_station),
                slave.outputs[0..@sizeOf(Y)],
            );
        }
    }

    pub fn pollWr(self: Line, io: std.Io, wr: []Wr) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        for (self.slaves, wr) |slave, *wr_station| {
            @memcpy(
                std.mem.asBytes(wr_station),
                slave.inputs[@sizeOf(X) .. @sizeOf(X) + @sizeOf(Wr)],
            );
        }
    }

    pub fn pollWw(self: Line, io: std.Io, ww: []Ww) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        for (self.slaves, ww) |slave, *ww_station| {
            @memcpy(
                std.mem.asBytes(ww_station),
                slave.outputs[@sizeOf(Y) .. @sizeOf(Y) + @sizeOf(Ww)],
            );
        }
    }

    pub fn sendY(self: Line, io: std.Io, y: []Y) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        for (self.slaves, y) |slave, *y_station| {
            @memcpy(
                slave.outputs[0..@sizeOf(Y)],
                std.mem.asBytes(y_station),
            );
        }
    }

    pub fn sendWw(self: Line, io: std.Io, ww: []Ww) !void {
        // Ensure all slaves in operational mode
        for (self.slaves) |slave| {
            if (slave.state != soem.EC_STATE_OPERATIONAL) {
                return error.SlaveNotOperational;
            }
        }
        try self.lock.lock(io);
        defer self.lock.unlock(io);
        for (self.slaves, ww) |slave, *ww_station| {
            @memcpy(
                slave.outputs[@sizeOf(Y) .. @sizeOf(Y) + @sizeOf(Ww)],
                std.mem.asBytes(ww_station),
            );
        }
    }
};
