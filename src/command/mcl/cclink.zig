const std = @import("std");
const mdfunc = @import("mdfunc");
const registers = @import("mcl.zig").registers;

pub const Index = std.math.IntFittingRange(0, 63);
pub const Id = std.math.IntFittingRange(1, 64);
pub const Range = struct {
    start: Index,
    end: Index,
};

// Restricts available channels for connection to 4 CC-Link slots.
pub const Channel = enum(u2) {
    cc_link_1slot = 0,
    cc_link_2slot = 1,
    cc_link_3slot = 2,
    cc_link_4slot = 3,

    pub fn path(c: Channel) ?i32 {
        return paths[@intFromEnum(c)];
    }

    /// Get path of channel, asserting that the path is opened.
    pub fn openedPath(self: Channel) Error!i32 {
        const chan_idx: u2 = @intFromEnum(self);
        if (paths[chan_idx]) |p| {
            return p;
        } else {
            return Error.ChannelUnopened;
        }
    }

    pub fn toMdfunc(c: Channel) mdfunc.Channel {
        return switch (c) {
            .cc_link_1slot => mdfunc.Channel.@"CC-Link (1 slot)",
            .cc_link_2slot => mdfunc.Channel.@"CC-Link (2 slot)",
            .cc_link_3slot => mdfunc.Channel.@"CC-Link (3 slot)",
            .cc_link_4slot => mdfunc.Channel.@"CC-Link (4 slot)",
        };
    }

    pub fn open(c: Channel) mdfunc.Error!void {
        const index: u2 = @intFromEnum(c);
        if (mdfunc.open(c.toMdfunc())) |p| {
            paths[index] = p;
        } else |err| switch (err) {
            mdfunc.Error.@"66: Channel-opened error" => {},
            else => |e| return e,
        }
    }

    pub fn close(channel: Channel) (Error || mdfunc.Error)!void {
        const index: u2 = @intFromEnum(channel);
        if (paths[index]) |p| {
            try mdfunc.close(p);
            paths[index] = null;
        } else {
            return Error.ChannelUnopened;
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

var paths: [4]?i32 = .{null} ** 4;

test {
    std.testing.refAllDecls(@This());
}
