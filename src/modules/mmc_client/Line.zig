const Line = @This();
const std = @import("std");
const api = @import("mmc-api");
const CoreResponse = @FieldType(api.protobuf.mmc.Response.body_union, "core");

index: Line.Index,
id: Line.Id,
axes: std.math.IntFittingRange(1, max_axis),
name: []u8,
velocity: f32,
acceleration: f32,
length: struct {
    axis: f32,
    carrier: f32,
},
drivers: std.math.IntFittingRange(1, max_driver),

/// Maximum number of drivers
pub const max_driver = 64 * 4;
pub const max_axis = max_driver * 3;
pub const Index = std.math.IntFittingRange(0, max_driver - 1);
pub const Id = std.math.IntFittingRange(1, max_driver);

pub fn init(
    gpa: std.mem.Allocator,
    index: Index,
    config: CoreResponse.TrackConfig.Line,
) !Line {
    var result: Line = undefined;
    if (config.axes > max_axis or config.drivers.items.len > max_driver) {
        return error.InvalidConfiguration;
    }
    result.index = index;
    result.id = @as(Id, index) + 1;
    result.acceleration = 7800; // mm/s^2
    result.velocity = 1200; // mm/s
    result.length = .{
        .axis = config.axis_length,
        .carrier = config.carrier_length,
    };
    result.name = try gpa.dupe(u8, config.name);
    result.axes = @intCast(config.axes);
    result.drivers = @intCast(config.drivers.items.len);
    return result;
}

pub fn deinit(self: *Line, gpa: std.mem.Allocator) void {
    self.index = 0;
    self.id = 0;
    self.acceleration = 0;
    self.velocity = 0;
    self.length = .{ .axis = 0, .carrier = 0 };
    gpa.free(self.name);
    self.name = &.{};
}

test {
    std.testing.refAllDecls(@This());
}
