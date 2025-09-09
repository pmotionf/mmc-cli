const Line = @This();
const std = @import("std");
const api = @import("mmc-api");
const Config = api.core_msg.Response.TrackConfig;

index: Line.Index,
id: Line.Id,
axes: u10,
name: []u8,
velocity: u6,
acceleration: u8,
length: struct {
    axis: f32,
    carrier: f32,
},

/// Maximum number of drivers
pub const max = 64 * 4;
pub const Index = std.math.IntFittingRange(0, max - 1);
pub const Id = std.math.IntFittingRange(1, max);

pub fn init(
    allocator: std.mem.Allocator,
    index: Index,
    config: Config.Line,
) !Line {
    var result: Line = undefined;
    if (config.axes > std.math.maxInt(u10)) return error.InvalidConfiguration;
    result.index = index;
    result.id = @as(Id, index) + 1;
    result.acceleration = 78;
    result.velocity = 12;
    result.length = .{
        .axis = config.axis_length,
        .carrier = config.carrier_length,
    };
    result.name = try allocator.dupe(u8, config.name);
    result.axes = @intCast(config.axes);
    return result;
}

pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
    self.index = 0;
    self.id = 0;
    self.acceleration = 0;
    self.velocity = 0;
    self.length = .{ .axis = 0, .carrier = 0 };
    allocator.free(self.name);
    self.name = &.{};
}
