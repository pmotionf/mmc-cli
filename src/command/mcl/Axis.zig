//! This module provides convenient indexing of system axes, both in terms of
//! line-level indexing and local station-level indexing.
const Axis = @This();

const std = @import("std");

const MclStation = @import("Station.zig");

station: *const MclStation,
index: Index,
id: Id,

pub const Index = struct {
    station: Station,
    line: Line,

    /// Local axis index within station.
    pub const Station = std.math.IntFittingRange(0, 2);
    /// Axis index within line.
    pub const Line = std.math.IntFittingRange(0, 64 * 4 * 3 - 1);
};

pub const Id = struct {
    station: Station,
    line: Line,

    /// Local axis ID within station.
    pub const Station = std.math.IntFittingRange(1, 3);
    /// Axis ID within line.
    pub const Line = std.math.IntFittingRange(1, 64 * 4 * 3);
};

test {
    std.testing.refAllDecls(@This());
}
