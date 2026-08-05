const std = @import("std");
const mdfunc = @import("mdfunc");

pub const registers = @import("mmc-api").registers;
const protocol = @import("protocol.zig");

pub const Config = @import("Config.zig");
pub const Axis = @import("Axis.zig");
pub const Station = @import("Station.zig");
pub const Line = @import("Line.zig");

const Mcl = @This();

lines: []Line,
connection: *protocol.Cclink,

pub const Distance = registers.Distance;
pub const Direction = registers.Direction;

/// Initialize the MCL library. This must be run before any other MCL library
/// functions, except functions in `Config.zig`, are called. This must also be
/// re-run after every configuration change to the system.
pub fn init(gpa: std.mem.Allocator, config: Config) !Mcl {
    const lines = try gpa.alloc(Line, config.lines.len);
    errdefer gpa.free(lines);
    var comm: *protocol.Cclink = try gpa.create(protocol.Cclink);
    errdefer gpa.destroy(comm);
    comm.channels = .init(gpa);
    errdefer comm.channels.deinit();
    for (config.lines) |line| {
        for (line.ranges) |range| {
            if (comm.channels.get(range.channel)) |_|
                continue
            else {
                try comm.channels.put(range.channel, null);
            }
        }
    }

    for (config.lines, lines, 0..) |line_config, *line, line_idx| {
        try line.init(gpa, @intCast(line_idx), line_config, comm);
    }
    return .{ .lines = lines, .connection = comm };
}

pub fn deinit(self: Mcl, gpa: std.mem.Allocator) void {
    for (self.lines) |*line| {
        line.deinit(gpa);
    }
    self.connection.channels.deinit();
    gpa.free(self.lines);
    gpa.destroy(self.connection);
}

/// Opens all channels used in all configured lines.
pub fn open(self: Mcl) !void {
    var channel_iterator = self.connection.channels.iterator();
    while (channel_iterator.next()) |channel| {
        channel.value_ptr.* = try channel.key_ptr.open();
    }
}

/// Closes all channels used in all configured lines.
pub fn close(self: Mcl) !void {
    var channel_iterator = self.connection.channels.iterator();
    while (channel_iterator.next()) |channel| {
        const path = channel.value_ptr.* orelse continue;
        channel.value_ptr.* = null;
        try mdfunc.close(path);
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
