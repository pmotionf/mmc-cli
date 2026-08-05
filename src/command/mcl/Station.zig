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

connection: protocol.Cclink.Station,

pub fn prev(self: Station) ?Station {
    if (self.index > 0) {
        return self.line.stations[self.index - 1];
    } else return null;
}

pub fn next(self: Station) ?Station {
    if (self.index < self.line.stations.len - 1) {
        return self.line.stations[self.index + 1];
    } else return null;
}

pub fn setY(
    self: Station,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.setY(offset);
}

pub fn resetY(
    self: Station,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.resetY(offset);
}

pub fn poll(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.pollX(self.x);
    try self.connection.pollY(self.y);
    try self.connection.pollWr(self.wr);
    try self.connection.pollWw(self.ww);
}

pub fn pollX(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.pollX(self.x);
}

pub fn pollY(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.pollY(self.y);
}

pub fn pollWr(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.pollWr(self.wr);
}

pub fn pollWw(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.pollWw(self.ww);
}

pub fn send(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.sendWw(self.ww);
    try self.connection.sendY(self.y);
}

pub fn sendY(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.sendY(self.y);
}

pub fn sendWw(self: Station) (protocol.Cclink.Error || mdfunc.Error)!void {
    try self.connection.sendWw(self.ww);
}

test {
    std.testing.refAllDecls(@This());
}
