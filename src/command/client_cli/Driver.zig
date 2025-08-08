const Driver = @This();
const Line = @import("Line.zig");
const Axis = @import("Axis.zig");
const std = @import("std");
const api = @import("mmc-api");
const SystemResponse = api.info_msg.Response.System;

line: *const Line,
index: Driver.Index,
id: Driver.Id,
axes: []Axis,

/// Maximum number of driver in a line
pub const max = 64 * 4;

pub const Index = std.math.IntFittingRange(0, Driver.max - 1);
pub const Id = std.math.IntFittingRange(1, Driver.max);
