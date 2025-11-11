const Line = @This();
const std = @import("std");
const api = @import("mmc-api");

index: Line.Index,
id: Line.Id,
axes: u10,
name: []u8,
velocity: struct { value: u10, low: bool },
acceleration: u8,
length: struct {
    axis: f32,
    carrier: f32,
},
drivers: std.math.IntFittingRange(1, max_axis),

/// Maximum number of drivers
pub const max_driver = 64 * 4;
pub const max_axis = max_driver * 3;
pub const Index = std.math.IntFittingRange(0, max_driver - 1);
pub const Id = std.math.IntFittingRange(1, max_driver);

pub fn init(
    allocator: std.mem.Allocator,
    index: Index,
    config: api.protobuf.mmc.core.Response.TrackConfig.Line,
) !Line {
    var result: Line = undefined;
    if (config.axes > std.math.maxInt(u10)) return error.InvalidConfiguration;
    result.index = index;
    result.id = @as(Id, index) + 1;
    result.acceleration = 78;
    result.velocity = .{ .value = 12, .low = false };
    result.length = .{
        .axis = config.axis_length,
        .carrier = config.carrier_length,
    };
    result.name = try allocator.dupe(u8, config.name);
    result.axes = @intCast(config.axes);
    result.drivers = @intCast(config.drivers);
    return result;
}

pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
    self.index = 0;
    self.id = 0;
    self.acceleration = 0;
    self.velocity = .{ .value = 0, .low = false };
    self.length = .{ .axis = 0, .carrier = 0 };
    allocator.free(self.name);
    self.name = &.{};
}
