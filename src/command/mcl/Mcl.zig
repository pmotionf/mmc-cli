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
connection: Connection,

pub const Distance = registers.Distance;
pub const Direction = registers.Direction;
pub const Connection = union(Kind) {
    cclink: *protocol.Cclink,
    ethercat: *protocol.Ethercat,

    const Kind = enum { cclink, ethercat };

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        kind: Kind,
    ) !Connection {
        switch (kind) {
            .cclink => {
                const cclink = try gpa.create(protocol.Cclink);
                cclink.* = .init(gpa);
                return .{ .cclink = cclink };
            },
            .ethercat => {
                const ethercat = try gpa.create(protocol.Ethercat);
                errdefer gpa.destroy(ethercat);
                ethercat.* = .{ .master = try .init(gpa, io), .slaves = &.{} };
                return .{ .ethercat = ethercat };
            },
        }
    }

    fn deinit(self: Connection, gpa: std.mem.Allocator) void {
        switch (self) {
            .cclink => |cclink| {
                cclink.deinit();
                gpa.destroy(cclink);
            },
            .ethercat => |ethercat| {
                ethercat.deinit(gpa);
                gpa.destroy(ethercat);
            },
        }
    }
};

/// Initialize the MCL library. This must be run before any other MCL library
/// functions, except functions in `Config.zig`, are called. This must also be
/// re-run after every configuration change to the system.
pub fn init(gpa: std.mem.Allocator, io: std.Io, config: Config) !Mcl {
    const lines = try gpa.alloc(Line, config.lines.len);
    errdefer gpa.free(lines);
    var comm: Connection = try .init(
        gpa,
        io,
        switch (config.lines[0].drivers[0]) {
            .cclink => .cclink,
            .ethercat => .ethercat,
        },
    );
    errdefer comm.deinit(gpa);
    var driver_num: usize = 0;
    for (config.lines) |line| {
        for (line.drivers) |driver| {
            if (comm == .cclink) {
                if (comm.cclink.channels.get(driver.cclink.channel)) |_|
                    continue
                else {
                    try comm.cclink.channels.put(driver.cclink.channel, null);
                }
            }
            driver_num += 1;
        }
    }
    if (comm == .ethercat) {
        comm.ethercat.slaves =
            try gpa.alloc(protocol.Ethercat.soem.ec_slavet, driver_num);
    }
    for (config.lines, lines, 0..) |line_config, *line, line_idx| {
        try line.init(gpa, @intCast(line_idx), line_config, &comm);
    }
    return .{ .lines = lines, .connection = comm };
}

pub fn deinit(self: Mcl, gpa: std.mem.Allocator) void {
    for (self.lines) |*line| {
        line.deinit(gpa);
    }
    self.connection.deinit(gpa);
    gpa.free(self.lines);
}

/// Opens all channels used in all configured lines.
pub fn open(self: Mcl) !void {
    var channel_iterator =
        self.connection.cclink.channels.iterator();
    while (channel_iterator.next()) |channel| {
        channel.value_ptr.* = try channel.key_ptr.open();
    }
}

/// Closes all channels used in all configured lines.
pub fn close(self: Mcl) !void {
    var channel_iterator = self.connection.cclink.channels.iterator();
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
