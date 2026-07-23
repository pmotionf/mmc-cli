const std = @import("std");
const mdfunc = @import("mdfunc");

pub const registers = @import("mmc-api").registers;
pub const connection = @import("cclink.zig");

pub const Config = @import("Config.zig");
pub const Axis = @import("Axis.zig");
pub const Station = @import("Station.zig");
pub const Line = @import("Line.zig");

pub const version: std.SemanticVersion =
    std.SemanticVersion.parse("2.0.1") catch
        @compileError("InvalidVersionMCL");

pub var lines: []const Line = &.{};

// Identical slice of lines as above without the const modifier, allowing the
// MCL library to initialize lines but preventing consumers from mutating.
var _lines: []Line = &.{};

pub const Distance = registers.Distance;
pub const Direction = registers.Direction;

var used_channels: [4]bool = .{false} ** 4;
var allocator: ?std.mem.Allocator = null;

/// Initialize the MCL library. This must be run before any other MCL library
/// functions, except functions in `Config.zig`, are called. This must also be
/// re-run after every configuration change to the system.
pub fn init(a: std.mem.Allocator, config: Config) !void {
    used_channels = .{false} ** 4;
    _lines = try a.alloc(Line, config.lines.len);
    errdefer a.free(_lines);

    for (config.lines) |line| {
        for (line.ranges) |range| {
            used_channels[@intFromEnum(range.channel)] = true;
        }
    }

    for (config.lines, 0..) |line, line_idx| {
        try Line.init(a, &_lines[line_idx], @intCast(line_idx), line);
    }
    lines = _lines;
    allocator = a;
}

pub fn deinit() void {
    if (allocator) |_| {
        for (_lines) |*line| {
            line.deinit();
        }
    }
    _lines = &.{};
    lines = &.{};
    allocator = null;
}

/// Opens all channels used in all configured lines.
pub fn open() !void {
    for (used_channels, 0..) |used, i| {
        if (used) {
            const chan: connection.Channel = @enumFromInt(i);
            chan.open() catch |e| switch (e) {
                mdfunc.Error.@"66: Channel-opened error" => {},
                else => return e,
            };
        }
    }
}

/// Closes all channels used in all configured lines.
pub fn close() !void {
    for (used_channels, 0..) |used, i| {
        if (used) {
            const chan: connection.Channel = @enumFromInt(i);
            chan.close() catch |e| switch (e) {
                else => return e,
            };
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
