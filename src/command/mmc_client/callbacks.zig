const std = @import("std");
const api = @import("api.zig");
const client = @import("../mmc_client.zig");
pub const command = @import("callbacks/command.zig");
pub const connection = @import("callbacks/connection.zig");
pub const logging = @import("callbacks/logging.zig");
pub const state = @import("callbacks/state.zig");

pub const Filter = union(enum) {
    carrier: [1]u32,
    driver: u32,
    axis: u32,

    pub fn parse(filter: []const u8) (error{InvalidParameter} || std.fmt.ParseIntError)!Filter {
        var suffix_idx: usize = 0;
        for (filter) |c| {
            if (std.ascii.isDigit(c)) suffix_idx += 1 else break;
        }
        // No digit is recognized.
        if (suffix_idx == 0) return error.InvalidParameter;
        const id = try std.fmt.parseUnsigned(u32, filter[0..suffix_idx], 0);

        // Check for single character suffix.
        if (filter.len - suffix_idx == 1) {
            if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "a"))
                return Filter{ .axis = id }
            else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "c"))
                return Filter{ .carrier = [1]u32{id} }
            else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "d"))
                return Filter{ .driver = id };
        }
        // Check for `axis` suffix
        else if (filter.len - suffix_idx == 4 and
            std.ascii.eqlIgnoreCase(filter[suffix_idx..], "axis"))
            return Filter{ .axis = id }
            // Check for `driver` suffix
        else if (filter.len - suffix_idx == 6 and
            std.ascii.eqlIgnoreCase(filter[suffix_idx..], "driver"))
            return Filter{ .driver = id }
            // Check for `carrier` suffix
        else if (std.ascii.eqlIgnoreCase(filter[suffix_idx..], "carrier"))
            return Filter{ .carrier = [1]u32{id} };
        return error.InvalidParameter;
    }

    pub fn toProtobuf(filter: *Filter) api.api.protobuf.mmc.info.Request.Track.filter_union {
        return switch (filter.*) {
            .axis => |axis_id| .{
                .axes = .{
                    .start = axis_id,
                    .end = axis_id,
                },
            },
            .driver => |driver_id| .{
                .drivers = .{
                    .start = driver_id,
                    .end = driver_id,
                },
            },
            .carrier => .{
                .carriers = .{ .ids = .fromOwnedSlice(&filter.carrier) },
            },
        };
    }
};

pub fn matchLine(name: []const u8) !usize {
    for (client.lines) |line| {
        if (std.mem.eql(u8, line.name, name)) return line.index;
    } else return error.LineNameNotFound;
}
