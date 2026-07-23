const std = @import("std");
const mdfunc = @import("mdfunc");

pub const registers = @import("mmc-api").registers;
pub const cclink = @import("cclink.zig");

pub const Config = @import("Config.zig");
pub const Axis = @import("Axis.zig");
pub const Station = @import("Station.zig");
pub const Line = @import("Line.zig");

const Mcl = @This();

lines: []Line,

pub const Distance = registers.Distance;
pub const Direction = registers.Direction;

var used_channels: [4]bool = .{false} ** 4;

/// Initialize the MCL library. This must be run before any other MCL library
/// functions, except functions in `Config.zig`, are called. This must also be
/// re-run after every configuration change to the system.
pub fn init(gpa: std.mem.Allocator, config: Config) !Mcl {
    const lines = try gpa.alloc(Line, config.lines.len);
    errdefer gpa.free(lines);
    used_channels = .{false} ** 4;

    for (config.lines) |line| {
        for (line.ranges) |range| {
            used_channels[@intFromEnum(range.channel)] = true;
        }
    }

    for (config.lines, lines, 0..) |line_config, *line, line_idx| {
        try line.init(gpa, @intCast(line_idx), line_config);
    }
    return .{ .lines = lines };
}

pub fn deinit(self: Mcl, gpa: std.mem.Allocator) void {
    for (self.lines) |*line| {
        line.deinit(gpa);
    }
    gpa.free(self.lines);
}

/// Opens all channels used in all configured lines.
pub fn open(_: Mcl) !void {
    for (used_channels, 0..) |used, i| {
        if (used) {
            const chan: cclink.Channel = @enumFromInt(i);
            chan.open() catch |e| switch (e) {
                mdfunc.Error.@"66: Channel-opened error" => {},
                else => return e,
            };
        }
    }
}

/// Closes all channels used in all configured lines.
pub fn close(_: Mcl) !void {
    for (used_channels, 0..) |used, i| {
        if (used) {
            const chan: cclink.Channel = @enumFromInt(i);
            chan.close() catch |e| switch (e) {
                else => return e,
            };
        }
    }
}

pub fn getLine(
    self: Mcl,
    line_name: []const u8,
) error{LineNameNotFound}!*Line {
    for (self.lines) |*line| {
        if (std.mem.eql(u8, line.name, line_name)) return line;
    } else return error.LineNameNotFound;
}

test {
    std.testing.refAllDecls(@This());
}
