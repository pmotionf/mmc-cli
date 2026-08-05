const std = @import("std");
const mdfunc = @import("mdfunc");
const registers = @import("../Mcl.zig").registers;

const Cclink = @This();

const X = registers.X;
const Y = registers.Y;
const Wr = registers.Wr;
const Ww = registers.Ww;

channels: std.hash_map.AutoHashMap(Channel, ?i32),

pub const Index = std.math.IntFittingRange(0, 63);
pub const Id = std.math.IntFittingRange(1, 64);
pub const Range = struct {
    /// CC-Link Channel.
    channel: Channel,
    /// CC-Link Station ID. Start of range, inclusive.
    start: Id,
    /// CC-Link Station ID. End of range, inclusive.
    end: Id,
};

// The path to CC-Link channel.
pub const Channel = enum(u2) {
    cc_link_1slot = 0,
    cc_link_2slot = 1,
    cc_link_3slot = 2,
    cc_link_4slot = 3,

    pub fn toMdfunc(channel: Channel) mdfunc.Channel {
        return switch (channel) {
            .cc_link_1slot => mdfunc.Channel.@"CC-Link (1 slot)",
            .cc_link_2slot => mdfunc.Channel.@"CC-Link (2 slot)",
            .cc_link_3slot => mdfunc.Channel.@"CC-Link (3 slot)",
            .cc_link_4slot => mdfunc.Channel.@"CC-Link (4 slot)",
        };
    }

    /// Open the CC-Link channel and return its path.
    pub fn open(channel: Channel) mdfunc.Error!i32 {
        if (mdfunc.open(channel.toMdfunc())) |p| {
            return p;
        } else |err| return err;
    }
};

pub const Station = struct {
    /// CC-Link channel path
    path: *?i32,
    /// CC-Link driver index of the channel
    index: i32,

    pub fn init(channel: Channel, index: Index) Station {
        return .{ .path = channel.path, .devno = @as(i32, index) };
    }

    pub fn setY(
        self: Station,
        /// Bitwise offset of desired field (0..).
        offset: u6,
    ) (Error || mdfunc.Error)!void {
        const devno: i32 =
            @as(i32, self.index) * @bitSizeOf(Y) +
            @as(i32, offset);
        try mdfunc.devSetEx(self.path.* orelse return Error.ChannelUnopened, 0, 0xFF, .DevY, devno);
    }

    pub fn resetY(
        self: Station,
        /// Bitwise offset of desired field (0..).
        offset: u6,
    ) (Error || mdfunc.Error)!void {
        const devno: i32 =
            @as(i32, self.index) * @bitSizeOf(Y) +
            @as(i32, offset);
        try mdfunc.devRstEx(self.path.* orelse return Error.ChannelUnopened, 0, 0xFF, .DevY, devno);
    }

    pub fn pollX(self: Station, x: *X) (Error || mdfunc.Error)!void {
        const read_bytes = try mdfunc.receiveEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevX,
            @as(i32, self.index) * @bitSizeOf(X),
            std.mem.asBytes(x),
        );
        if (read_bytes != @sizeOf(X)) {
            return Error.UnexpectedReadSizeX;
        }
    }

    pub fn pollY(self: Station, y: *Y) (Error || mdfunc.Error)!void {
        const read_bytes = try mdfunc.receiveEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevY,
            @as(i32, self.index) * @bitSizeOf(Y),
            std.mem.asBytes(y),
        );
        if (read_bytes != @sizeOf(Y)) {
            return Error.UnexpectedReadSizeY;
        }
    }

    pub fn pollWr(
        self: Station,
        wr: *Wr,
    ) (Error || mdfunc.Error)!void {
        const read_bytes = try mdfunc.receiveEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevWr,
            @as(i32, self.index) * 16, // 16 from MELSEC manual.
            std.mem.asBytes(wr),
        );
        if (read_bytes != @sizeOf(Wr)) {
            return Error.UnexpectedReadSizeWr;
        }
    }

    pub fn pollWw(
        self: Station,
        ww: *Ww,
    ) (Error || mdfunc.Error)!void {
        const read_bytes = try mdfunc.receiveEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevWw,
            @as(i32, self.index) * 16, // 16 from MELSEC manual.
            std.mem.asBytes(ww),
        );
        if (read_bytes != @sizeOf(Wr)) {
            return Error.UnexpectedReadSizeWr;
        }
    }

    pub fn sendY(self: Station, y: *registers.Y) (Error || mdfunc.Error)!void {
        const sent_bytes = try mdfunc.sendEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevY,
            @as(i32, self.index) * @bitSizeOf(Y),
            std.mem.asBytes(y),
        );
        if (sent_bytes != @sizeOf(Y)) {
            return Error.UnexpectedSendSizeY;
        }
    }

    pub fn sendWw(
        self: Station,
        ww: *registers.Ww,
    ) (Error || mdfunc.Error)!void {
        const sent_bytes = try mdfunc.sendEx(
            self.path.* orelse return Error.ChannelUnopened,
            0,
            0xFF,
            .DevWw,
            @as(i32, self.index) * 16,
            std.mem.asBytes(ww),
        );
        if (sent_bytes != @sizeOf(Ww)) {
            return Error.UnexpectedSendSizeWw;
        }
    }
};

pub const Line = struct {
    ranges: []Range,
    channels: *std.hash_map.AutoHashMap(Channel, ?i32),

    pub fn init(
        gpa: std.mem.Allocator,
        ranges: []const Range,
        cclink: *Cclink,
    ) std.mem.Allocator.Error!Line {
        return .{
            .ranges = try gpa.dupe(Range, ranges),
            .channels = &cclink.channels,
        };
    }

    pub fn deinit(self: Line, gpa: std.mem.Allocator) void {
        gpa.free(self.ranges);
    }

    pub fn pollX(self: Line, x: []X) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const read_bytes = try mdfunc.receiveEx(
                path,
                0,
                0xFF,
                .DevX,
                @as(i32, range.start - 1) * @bitSizeOf(X),
                std.mem.sliceAsBytes(x[range_offset..][0..range_len]),
            );
            if (read_bytes != @sizeOf(X) * range_len) {
                return Error.UnexpectedReadSizeX;
            }
        }
    }

    pub fn pollY(self: Line, y: []Y) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const read_bytes = try mdfunc.receiveEx(
                path,
                0,
                0xFF,
                .DevY,
                @as(i32, range.start - 1) * @bitSizeOf(Y),
                std.mem.sliceAsBytes(y[range_offset..][0..range_len]),
            );
            if (read_bytes != @sizeOf(Y) * range_len) {
                return Error.UnexpectedReadSizeY;
            }
        }
    }

    pub fn pollWr(self: Line, wr: []Wr) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const read_bytes = try mdfunc.receiveEx(
                path,
                0,
                0xFF,
                .DevWr,
                @as(i32, range.start - 1) * 16, // 16 from MELSEC manual.
                std.mem.sliceAsBytes(wr[range_offset..][0..range_len]),
            );
            if (read_bytes != @sizeOf(Wr) * range_len) {
                return Error.UnexpectedReadSizeWr;
            }
        }
    }

    pub fn pollWw(self: Line, ww: []Ww) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const read_bytes = try mdfunc.receiveEx(
                path,
                0,
                0xFF,
                .DevWw,
                @as(i32, range.start - 1) * 16, // 16 from MELSEC manual.
                std.mem.sliceAsBytes(ww[range_offset..][0..range_len]),
            );
            if (read_bytes != @sizeOf(Ww) * range_len) {
                return Error.UnexpectedReadSizeWw;
            }
        }
    }

    pub fn sendY(self: Line, y: []Y) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const sent_bytes = try mdfunc.sendEx(
                path,
                0,
                0xFF,
                .DevY,
                @as(i32, range.start - 1) * @bitSizeOf(Y),
                std.mem.sliceAsBytes(y[range_offset..][0..range_len]),
            );
            if (sent_bytes != @sizeOf(Y) * range_len) {
                return Error.UnexpectedSendSizeY;
            }
        }
    }

    pub fn sendWw(self: Line, ww: []Ww) (Error || mdfunc.Error)!void {
        var range_offset: usize = 0;
        for (self.ranges) |range| {
            const path = self.channels.get(range.channel).? orelse
                return Error.ChannelUnopened;
            const range_len: usize =
                @as(usize, range.end - range.start) + 1;
            defer range_offset += range_len;

            const sent_bytes = try mdfunc.sendEx(
                path,
                0,
                0xFF,
                .DevWw,
                @as(i32, range.start - 1) * 16, // 16 from MELSEC manual.
                std.mem.sliceAsBytes(ww[range_offset..][0..range_len]),
            );
            if (sent_bytes != @sizeOf(Ww) * range_len) {
                return Error.UnexpectedSendSizeWw;
            }
        }
    }
};

pub const Error = error{
    UnexpectedReadSizeX,
    UnexpectedReadSizeY,
    UnexpectedReadSizeWr,
    UnexpectedReadSizeWw,
    UnexpectedSendSizeY,
    UnexpectedSendSizeWw,
    ChannelUnopened,
};

test {
    std.testing.refAllDecls(@This());
}
