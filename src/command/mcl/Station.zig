const Station = @This();

const std = @import("std");
const mdfunc = @import("mdfunc");
const registers = @import("mcl.zig").registers;
const cclink = @import("cclink.zig");
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

connection: struct {
    channel: cclink.Channel,
    index: cclink.Index,
},

pub fn prev(station: Station) ?Station {
    if (station.index > 0) {
        return station.line.stations[station.index - 1];
    } else return null;
}

pub fn next(station: Station) ?Station {
    if (station.index < station.line.stations.len - 1) {
        return station.line.stations[station.index + 1];
    } else return null;
}

pub fn setY(
    station: Station,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) (cclink.Error || mdfunc.Error)!void {
    const path: i32 = try station.connection.channel.openedPath();
    const devno: i32 = @as(i32, station.connection.index) * @bitSizeOf(Y) +
        @as(i32, offset);
    try mdfunc.devSetEx(path, 0, 0xFF, .DevY, devno);
}

pub fn resetY(
    station: Station,
    /// Bitwise offset of desired field (0..).
    offset: u6,
) (cclink.Error || mdfunc.Error)!void {
    const path: i32 = try station.connection.channel.openedPath();
    const devno: i32 = @as(i32, station.connection.index) * @bitSizeOf(Y) +
        @as(i32, offset);
    try mdfunc.devRstEx(path, 0, 0xFF, .DevY, devno);
}

pub fn poll(station: Station) (cclink.Error || mdfunc.Error)!void {
    try station.pollX();
    try station.pollY();
    try station.pollWr();
    try station.pollWw();
}

pub fn pollX(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const read_bytes = try mdfunc.receiveEx(
        path,
        0,
        0xFF,
        .DevX,
        @as(i32, station.connection.index) * @bitSizeOf(X),
        std.mem.asBytes(station.x),
    );
    if (read_bytes != @sizeOf(X)) {
        return cclink.Error.UnexpectedReadSizeX;
    }
}

pub fn pollY(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const read_bytes = try mdfunc.receiveEx(
        path,
        0,
        0xFF,
        .DevY,
        @as(i32, station.connection.index) * @bitSizeOf(Y),
        std.mem.asBytes(station.y),
    );
    if (read_bytes != @sizeOf(Y)) {
        return cclink.Error.UnexpectedReadSizeY;
    }
}

pub fn pollWr(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const read_bytes = try mdfunc.receiveEx(
        path,
        0,
        0xFF,
        .DevWr,
        @as(i32, station.connection.index) * 16, // 16 from MELSEC manual.
        std.mem.asBytes(station.wr),
    );
    if (read_bytes != @sizeOf(Wr)) {
        return cclink.Error.UnexpectedReadSizeWr;
    }
}

pub fn pollWw(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const read_bytes = try mdfunc.receiveEx(
        path,
        0,
        0xFF,
        .DevWw,
        @as(i32, station.connection.index) * 16, // 16 from MELSEC manual.
        std.mem.asBytes(station.ww),
    );
    if (read_bytes != @sizeOf(Wr)) {
        return cclink.Error.UnexpectedReadSizeWr;
    }
}

pub fn send(station: Station) (cclink.Error || mdfunc.Error)!void {
    try station.sendWw();
    try station.sendY();
}

pub fn sendY(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const sent_bytes = try mdfunc.sendEx(
        path,
        0,
        0xFF,
        .DevY,
        @as(i32, station.connection.index) * @bitSizeOf(Y),
        std.mem.asBytes(station.y),
    );
    if (sent_bytes != @sizeOf(Y)) {
        return cclink.Error.UnexpectedSendSizeY;
    }
}

pub fn sendWw(station: Station) (cclink.Error || mdfunc.Error)!void {
    const path = try station.connection.channel.openedPath();
    const sent_bytes = try mdfunc.sendEx(
        path,
        0,
        0xFF,
        .DevWw,
        @as(i32, station.connection.index) * 16,
        std.mem.asBytes(station.ww),
    );
    if (sent_bytes != @sizeOf(Ww)) {
        return cclink.Error.UnexpectedSendSizeWw;
    }
}

test {
    std.testing.refAllDecls(@This());
}
