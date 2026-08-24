const Config = @This();

const std = @import("std");
const mcl = @import("Mcl.zig");
const protocol = @import("protocol.zig");

lines: []Line,

pub const Line = struct {
    /// Line name
    name: []const u8,
    /// Total number of axes in line.
    axes: mcl.Axis.Id.Line,
    /// CC-Link Station ranges.
    drivers: []protocol.Config,
    axis: AxisConfig,
    slider: Slider,

    pub const Range = struct {
        /// CC-Link Channel.
        channel: mcl.cclink.Channel,
        /// CC-Link Station ID. Start of range, inclusive.
        start: mcl.cclink.Id,
        /// CC-Link Station ID. End of range, inclusive.
        end: mcl.cclink.Id,
    };

    pub const AxisConfig = struct {
        /// Axis length, in millimeters.
        length: f32,
    };

    pub const Slider = struct {
        /// Slider dimension parallel to slider movement, in millimeters.
        length: f32,
        /// Slider dimension perpendicular to slider movement, in millimeters.
        width: f32,
    };
};

pub fn validate(c: Config) !void {
    if (c.lines.len == 0 or c.lines.len > 64 * 4) {
        return error.ConfigInvalidNumberOfLines;
    }

    var total_stations_num: usize = 0;
    var used_stations: [64 * 4]bool = .{false} ** (64 * 4);

    for (c.lines) |line| {
        var total_line_stations: usize = 0;
        if (line.axes == 0 or line.axes > 64 * 4 * 3) {
            return error.ConfigInvalidLineAxes;
        }
        var total_axes: usize = 0;
        for (line.drivers) |driver| {
            switch (driver) {
                .cclink => |cclink| {
                    if (cclink.station_id == 0 or cclink.station_id > 64) {
                        return error.ConfigInvalidStationId;
                    }
                    const channel_offset: usize =
                        64 * @as(usize, @intFromEnum(cclink.channel));
                    const station_idx =
                        channel_offset + @as(usize, cclink.station_id - 1);
                    if (used_stations[station_idx]) {
                        return error.ConfigOverlappingLineStationRanges;
                    }
                    total_axes += cclink.axes;
                    used_stations[station_idx] = true;
                },
                .ethercat => |ethercat| {
                    if (ethercat.station_id == 0 or ethercat.station_id > 256) {
                        return error.ConfigInvalidStationId;
                    }
                    const station_idx = @as(usize, ethercat.station_id - 1);
                    total_axes += ethercat.axes;
                    used_stations[station_idx] = true;
                },
            }
            total_stations_num += 1;
            total_line_stations += 1;
        }

        if (total_axes != line.axes) return error.ConfigTotalAxesMismatch;
    }

    if (total_stations_num == 0 or total_stations_num > 256) {
        return error.ConfigInvalidTotalNumberOfStations;
    }
}

test {
    std.testing.refAllDecls(@This());
}
