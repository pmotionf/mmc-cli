const Line = @This();

const std = @import("std");
const mdfunc = @import("mdfunc");
const cclink = @import("cclink.zig");
const Axis = @import("Axis.zig");
const Station = @import("Station.zig");
const Config = @import("Config.zig");

// The maximum number of stations is also the maximum number of lines, as
// there can be a minimum of one station per line.
pub const Index = Station.Index;
pub const Id = Station.Id;

name: []const u8,
index: Index,
id: Id,
speed: u7,
acceleration: u7,
slider_length: f32, // in millimeters

/// Axes that make up line. Each axis contains both its own line index and
/// local station index.
axes: []Axis,

/// Stations that make up line.
stations: []Station,

x: []Station.X,
y: []Station.Y,
wr: []Station.Wr,
ww: []Station.Ww,

connection: []Range,

const Range = struct {
    channel: cclink.Channel,
    range: cclink.Range,
};

pub fn init(
    self: *Line,
    gpa: std.mem.Allocator,
    line_index: Index,
    config: Config.Line,
) !void {
    self.index = line_index;
    self.id = line_index + 1;
    self.acceleration = 40;
    self.speed = 40;
    self.slider_length = config.slider.length;
    self.name = try gpa.dupe(u8, config.name);
    errdefer gpa.free(self.name);
    self.connection = try gpa.alloc(Range, config.ranges.len);
    errdefer gpa.free(self.connection);
    self.axes = try gpa.alloc(Axis, config.axes);
    errdefer gpa.free(self.axes);
    self.stations = try gpa.alloc(Station, (config.axes - 1) / 3 + 1);
    errdefer gpa.free(self.stations);
    self.x = try gpa.alloc(Station.X, self.stations.len);
    errdefer gpa.free(self.x);
    self.y = try gpa.alloc(Station.Y, self.stations.len);
    errdefer gpa.free(self.y);
    self.wr = try gpa.alloc(Station.Wr, self.stations.len);
    errdefer gpa.free(self.wr);
    self.ww = try gpa.alloc(Station.Ww, self.stations.len);
    errdefer gpa.free(self.ww);

    @memset(self.x, std.mem.zeroes(Station.X));
    @memset(self.y, std.mem.zeroes(Station.Y));
    @memset(self.wr, std.mem.zeroes(Station.Wr));
    @memset(self.ww, std.mem.zeroes(Station.Ww));

    var num_axes: usize = 0;

    for (config.ranges, 0..) |range, range_i| {
        self.connection[range_i] = .{
            .channel = range.channel,
            .range = .{
                .start = @intCast(range.start - 1),
                .end = @intCast(range.end - 1),
            },
        };
        for (0..range.end - range.start + 1) |station_i| {
            const start_num_axes = num_axes;
            for (0..3) |axis_i| {
                if (num_axes >= self.axes.len) break;
                self.axes[num_axes] = .{
                    .station = &self.stations[station_i],
                    .index = .{
                        .station = @intCast(axis_i),
                        .line = @intCast(num_axes),
                    },
                    .id = .{
                        .station = @intCast(axis_i + 1),
                        .line = @intCast(num_axes + 1),
                    },
                    .length = config.axis.length,
                };
                num_axes += 1;
            }
            self.stations[station_i] = .{
                .line = self,
                .index = @intCast(station_i),
                .id = @intCast(station_i + 1),
                .x = &self.x[station_i],
                .y = &self.y[station_i],
                .wr = &self.wr[station_i],
                .ww = &self.ww[station_i],
                .axes = self.axes[start_num_axes..num_axes],
                .connection = .{
                    .channel = range.channel,
                    .index = @intCast(range.start - 1 + station_i),
                },
            };
        }
    }
}

pub fn deinit(self: Line, gpa: std.mem.Allocator) void {
    gpa.free(self.name);
    gpa.free(self.axes);
    gpa.free(self.stations);
    gpa.free(self.x);
    gpa.free(self.y);
    gpa.free(self.wr);
    gpa.free(self.ww);
    gpa.free(self.connection);
}

pub fn poll(line: Line) !void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const x_read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevX,
            @as(i32, range.range.start) * @bitSizeOf(Station.X),
            std.mem.sliceAsBytes(line.x[range_offset..][0..range_len]),
        );
        if (x_read_bytes != @sizeOf(Station.X) * range_len) {
            return cclink.Error.UnexpectedReadSizeX;
        }

        const y_read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevY,
            @as(i32, range.range.start) * @bitSizeOf(Station.Y),
            std.mem.sliceAsBytes(line.y[range_offset..][0..range_len]),
        );
        if (y_read_bytes != @sizeOf(Station.Y) * range_len) {
            return cclink.Error.UnexpectedReadSizeY;
        }

        const wr_read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevWr,
            @as(i32, range.range.start) * 16, // 16 from MELSEC manual.
            std.mem.sliceAsBytes(line.wr[range_offset..][0..range_len]),
        );
        if (wr_read_bytes != @sizeOf(Station.Wr) * range_len) {
            return cclink.Error.UnexpectedReadSizeWr;
        }
    }
}

pub fn pollX(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevX,
            @as(i32, range.range.start) * @bitSizeOf(Station.X),
            std.mem.sliceAsBytes(line.x[range_offset..][0..range_len]),
        );
        if (read_bytes != @sizeOf(Station.X) * range_len) {
            return cclink.Error.UnexpectedReadSizeX;
        }
    }
}

pub fn pollY(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevY,
            @as(i32, range.range.start) * @bitSizeOf(Station.Y),
            std.mem.sliceAsBytes(line.y[range_offset..][0..range_len]),
        );
        if (read_bytes != @sizeOf(Station.Y) * range_len) {
            return cclink.Error.UnexpectedReadSizeY;
        }
    }
}

pub fn pollWr(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevWr,
            @as(i32, range.range.start) * 16, // 16 from MELSEC manual.
            std.mem.sliceAsBytes(line.wr[range_offset..][0..range_len]),
        );
        if (read_bytes != @sizeOf(Station.Wr) * range_len) {
            return cclink.Error.UnexpectedReadSizeWr;
        }
    }
}

pub fn pollWw(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const read_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevWw,
            @as(i32, range.range.start) * 16, // 16 from MELSEC manual.
            std.mem.sliceAsBytes(line.ww[range_offset..][0..range_len]),
        );
        if (read_bytes != @sizeOf(Station.Ww) * range_len) {
            return cclink.Error.UnexpectedReadSizeWw;
        }
    }
}

pub fn send(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const y_sent_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevY,
            @as(i32, range.range.start) * @bitSizeOf(Station.Y),
            std.mem.sliceAsBytes(line.y[range_offset..][0..range_len]),
        );
        if (y_sent_bytes != @sizeOf(Station.Y) * range_len) {
            return cclink.Error.UnexpectedSendSizeY;
        }

        const ww_sent_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevWw,
            @as(i32, range.range.start) * 16, // 16 from MELSEC manual.
            std.mem.sliceAsBytes(line.ww[range_offset..][0..range_len]),
        );
        if (ww_sent_bytes != @sizeOf(Station.Ww) * range_len) {
            return cclink.Error.UnexpectedSendSizeWw;
        }
    }
}

pub fn sendY(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const sent_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevY,
            @as(i32, range.range.start) * @bitSizeOf(Station.Y),
            std.mem.sliceAsBytes(line.y[range_offset..][0..range_len]),
        );
        if (sent_bytes != @sizeOf(Station.Y) * range_len) {
            return cclink.Error.UnexpectedSendSizeY;
        }
    }
}

pub fn sendWw(line: Line) (cclink.Error || mdfunc.Error)!void {
    var range_offset: usize = 0;
    for (line.connection) |range| {
        const path = try range.channel.openedPath();
        const range_len: usize =
            @as(usize, range.range.end - range.range.start) + 1;
        defer range_offset += range_len;

        const sent_bytes = try mdfunc.receiveEx(
            path,
            0,
            0xFF,
            .DevWw,
            @as(i32, range.range.start) * 16, // 16 from MELSEC manual.
            std.mem.sliceAsBytes(line.ww[range_offset..][0..range_len]),
        );
        if (sent_bytes != @sizeOf(Station.Ww) * range_len) {
            return cclink.Error.UnexpectedSendSizeWw;
        }
    }
}

/// Return the axis of the specified slider, if found in the system. If the
/// slider is split across two axes, then the auxiliary axis will be included
/// in the result tuple.
pub fn search(line: *const Line, slider_id: u16) ?struct { Axis, ?Axis } {
    var result: struct { Axis, ?Axis } = .{ undefined, null };

    for (line.axes) |axis| {
        const station = axis.station;
        const wr = station.wr;
        if (wr.slider_number.axis(axis.index.station) == slider_id) {
            result.@"0" = axis;

            if (axis.index.station == 2 and axis.id.line < line.axes.len) {
                const next_axis = line.axes[axis.index.line + 1];
                const next_station = next_axis.station;
                const next_wr = next_station.wr;

                if (next_wr.slider_number.axis(
                    next_axis.index.station,
                ) == slider_id) {
                    result.@"1" = next_axis;
                }
            }

            break;
        }
    } else {
        return null;
    }

    // If there are two detected contiguous axes, determine which is primary
    // and auxiliary.
    if (result.@"1") |*aux| {
        const main: *Axis = &result.@"0";
        const station = main.station;
        const wr = station.wr;
        const state = wr.slider_state.axis(main.index.station);
        if (state == .NextAxisAuxiliary or state == .NextAxisCompleted or
            state == .PrevAxisAuxiliary or state == .PrevAxisCompleted)
        {
            const temp = main.*;
            main.* = aux.*;
            aux.* = temp;
        } else if (state == .None) {
            const aux_station: *const Station = aux.station;
            const aux_wr = aux_station.wr;
            const aux_state = aux_wr.slider_state.axis(aux.index.station);
            if (aux_state != .None and
                aux_state != .NextAxisAuxiliary and
                aux_state != .NextAxisCompleted and
                aux_state != .PrevAxisAuxiliary and
                aux_state != .PrevAxisCompleted)
            {
                const temp = main.*;
                main.* = aux.*;
                aux.* = temp;
            }
        }
    }

    return result;
}

test "Line search" {
    var line: Line = undefined;
    const gpa = std.testing.allocator;
    var _ranges: [1]Config.Line.Range = .{.{
        .channel = .cc_link_1slot,
        .start = 1,
        .end = 3,
    }};
    const config: Line.Config.Line = .{
        .axes = 9,
        .axis = .{
            .length = 0.33,
        },
        .slider = .{ .length = 0.3, .width = 0.3 },
        .name = "test line",
        .ranges = &_ranges,
    };
    try line.init(gpa, 0, config);
    defer line.deinit(gpa);

    line.stations[1].wr.slider_number.axis3 = 1;
    line.stations[2].wr.slider_number.axis1 = 1;
    line.stations[1].wr.slider_state.axis3 = .NextAxisCompleted;
    line.stations[2].wr.slider_state.axis1 = .PosMoveCompleted;

    const _result = line.search(1);
    try std.testing.expect(_result != null);
    const result = _result.?;
    try std.testing.expect(result.@"1" != null);
    const main = result.@"0";
    const aux = result.@"1".?;
    try std.testing.expectEqual(7, main.id.line);
    try std.testing.expectEqual(6, aux.id.line);
}

test {
    std.testing.refAllDecls(@This());
}
