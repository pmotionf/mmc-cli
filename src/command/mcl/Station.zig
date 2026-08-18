const Station = @This();

const std = @import("std");
const mdfunc = @import("mdfunc");
const registers = @import("Mcl.zig").registers;
const protocol = @import("protocol.zig");
const Line = @import("Line.zig");
const Axis = @import("Axis.zig");

pub const X = registers.X;
pub const Y = registers.Y;
pub const Wr = registers.Wr;
pub const Ww = registers.Ww;

/// Index within configured line, spanning across connection ranges.
pub const Index = std.math.IntFittingRange(0, 64 * 4 - 1);
pub const Id = std.math.IntFittingRange(1, 64 * 4);

line: *const Line,
index: Index,
id: Id,
axes: []Axis,
x: *X,
y: *Y,
wr: *Wr,
ww: *Ww,

connection: Connection,

const Connection = union(enum) {
    cclink: protocol.Cclink.Station,
    ethercat: protocol.Ethercat.Station,
};

pub fn setY(
    self: Station,
    io: std.Io,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.setY(offset);
        },
        .ethercat => |ethercat| {
            try ethercat.setY(io, offset);
        },
    }
}

pub fn resetY(
    self: Station,
    io: std.Io,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.resetY(offset);
        },
        .ethercat => |ethercat| {
            try ethercat.resetY(io, offset);
        },
    }
}

pub fn poll(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.pollX(self.x);
            try cclink.pollY(self.y);
            try cclink.pollWr(self.wr);
            try cclink.pollWw(self.ww);
        },
        .ethercat => |ethercat| {
            try ethercat.pollX(io, self.x);
            try ethercat.pollY(io, self.y);
            try ethercat.pollWr(io, self.wr);
            try ethercat.pollWw(io, self.ww);
        },
    }
}

pub fn pollX(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.pollX(self.x);
        },
        .ethercat => |ethercat| {
            try ethercat.pollX(io, self.x);
        },
    }
}

pub fn pollY(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.pollY(self.y);
        },
        .ethercat => |ethercat| {
            try ethercat.pollY(io, self.y);
        },
    }
}

pub fn pollWr(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.pollWr(self.wr);
        },
        .ethercat => |ethercat| {
            try ethercat.pollWr(io, self.wr);
        },
    }
}

pub fn pollWw(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.pollWw(self.ww);
        },
        .ethercat => |ethercat| {
            try ethercat.pollWw(io, self.ww);
        },
    }
}

pub fn send(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.sendWw(self.ww);
            try cclink.sendY(self.y);
        },
        .ethercat => |ethercat| {
            try ethercat.sendWw(io, self.ww);
            try ethercat.sendY(io, self.y);
        },
    }
}

pub fn sendY(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.sendY(self.y);
        },
        .ethercat => |ethercat| {
            try ethercat.sendY(io, self.y);
        },
    }
}

pub fn sendWw(
    self: Station,
    io: std.Io,
) !void {
    switch (self.connection) {
        .cclink => |cclink| {
            try cclink.sendWw(self.ww);
        },
        .ethercat => |ethercat| {
            try ethercat.sendWw(io, self.ww);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
