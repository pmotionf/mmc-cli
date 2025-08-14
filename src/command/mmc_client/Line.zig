const Line = @This();
const Driver = @import("Driver.zig");
const Axis = @import("Axis.zig");
const std = @import("std");
const api = @import("mmc-api");
const Config = api.core_msg.Response.LineConfig;

index: Line.Index,
id: Line.Id,
axes: []Axis,
drivers: []Driver,
name: []u8,
velocity: u6,
acceleration: u8,
length: struct {
    axis: f32,
    carrier: f32,
},

/// Maximum number of drivers
pub const max = Driver.max;
pub const Index = Driver.Index;
pub const Id = Driver.Id;

pub fn init(
    self: *Line,
    allocator: std.mem.Allocator,
    index: Index,
    config: Config.Line,
) !void {
    std.debug.print(
        "axis len: {}\ncarrier len: {}\nname: {s}\naxes: {}\n",
        .{ config.length.?.axis, config.length.?.carrier, config.name.getSlice(), config.axes },
    );
    self.index = index;
    self.id = index + 1;
    self.acceleration = 78;
    self.velocity = 12;
    self.length = .{
        .axis = config.length.?.axis,
        .carrier = config.length.?.carrier,
    };
    self.name = try allocator.dupe(u8, config.name.getSlice());
    errdefer allocator.free(self.name);
    self.axes = try allocator.alloc(Axis, config.axes);
    errdefer allocator.free(self.axes);
    self.drivers = try allocator.alloc(Driver, config.axes / Axis.max.driver);
    errdefer allocator.free(self.drivers);
    for (self.drivers, 0..) |*driver, driver_idx| {
        driver.index = @intCast(driver_idx);
        driver.id = @intCast(driver_idx + 1);
        driver.line = self;
        driver.axes = self.axes[driver_idx *
            Axis.max.driver .. (driver_idx + 1) * Axis.max.driver];
        for (driver.axes, 0..) |*axis, axis_idx| {
            axis.index.driver = @intCast(axis_idx);
            axis.id.driver = axis.index.driver + 1;
            axis.index.line = @intCast(driver_idx * Axis.max.driver + axis_idx);
            axis.id.line = axis.index.line + 1;
            axis.driver = driver;
        }
    }
}

pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
    self.index = 0;
    self.id = 0;
    self.acceleration = 0;
    self.velocity = 0;
    self.length = .{ .axis = 0, .carrier = 0 };
    allocator.free(self.axes);
    self.axes = &.{};
    allocator.free(self.drivers);
    self.drivers = &.{};
    allocator.free(self.name);
    self.name = &.{};
}
