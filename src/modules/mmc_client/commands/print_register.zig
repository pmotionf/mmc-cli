const std = @import("std");
const client = @import("../../mmc_client.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

const InfoResponse = @FieldType(
    api.protobuf.mmc.Response.body_union,
    "info",
);

const Register = InfoResponse.Line.Register;
const registers = api.registers;

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_register");
    defer tracy_zone.end();

    const net = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    var filter: client.Filter = try .parse(params[1]);

    var register_x = false;
    var register_y = false;
    var register_wr = false;
    var register_ww = false;

    if (params[2].len > 0) {
        var it = std.mem.splitScalar(u8, params[2], ',');
        while (it.next()) |register_name| {
            if (std.ascii.eqlIgnoreCase(register_name, "x")) {
                register_x = true;
            } else if (std.ascii.eqlIgnoreCase(register_name, "y")) {
                register_y = true;
            } else if (std.ascii.eqlIgnoreCase(register_name, "wr")) {
                register_wr = true;
            } else if (std.ascii.eqlIgnoreCase(register_name, "ww")) {
                register_ww = true;
            } else return error.InvalidParameter;
        }
    } else {
        register_x = true;
        register_y = true;
        register_wr = true;
        register_ww = true;
    }

    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var line_array: [1]u32 = .{line.id};
    const lines: std.ArrayList(u32) = .fromOwnedSlice(&line_array);
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .lines = lines,
                        .register_x = register_x,
                        .register_y = register_y,
                        .register_wr = register_wr,
                        .register_ww = register_ww,
                        .filter = filter.toProtobuf(),
                    },
                },
            },
        },
    };

    try client.sendRequest(io, gpa, net, request);
    var decoded = try client.getResponse(gpa, io, net);
    defer decoded.deinit(gpa);
    const track = switch (decoded.body orelse return error.InvalidResponse) {
        .info => |info_resp| switch (info_resp.body orelse
            return error.InvalidResponse) {
            .track => |track_resp| track_resp,
            .request_error => |req_err| {
                return client.error_response.throwInfoError(req_err);
            },
            else => return error.InvalidResponse,
        },
        .request_error => |req_err| {
            return client.error_response.throwMmcError(req_err);
        },
        else => return error.InvalidResponse,
    };

    if (track.lines.items.len != 1) return error.InvalidResponse;

    const track_line = &track.lines.items[0];
    if (track_line.id != line.id) return error.InvalidResponse;

    var stdout = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout.interface;

    if (std.ascii.eqlIgnoreCase(params[3], "raw")) {
        // Raw register print
        if (register_x) {
            for (track_line.register_x.items) |item| {
                try writer.print(
                    "Line: {s}, Driver: {d}\n",
                    .{ line_name, item.driver },
                );
                for (0..@bitSizeOf(@TypeOf(item.value.items[0]))) |i| {
                    try writer.print("X[0x{X:0>4}] {d}\n", .{
                        i,
                        @as(u1, @truncate(item.value.items[0] >> @intCast(i))),
                    });
                }
            }
        }
        if (register_y) {
            for (track_line.register_y.items) |item| {
                try writer.print(
                    "Line: {s}, Driver: {d}\n",
                    .{ line_name, item.driver },
                );
                for (0..@bitSizeOf(@TypeOf(item.value.items[0]))) |i| {
                    try writer.print("Y[0x{X:0>4}] {d}\n", .{
                        i,
                        @as(u1, @truncate(item.value.items[0] >> @intCast(i))),
                    });
                }
            }
        }

        if (register_ww) {
            for (track_line.register_ww.items) |item| {
                try writer.print(
                    "Line: {s}, Driver: {d}\n",
                    .{ line_name, item.driver },
                );
                var ww: [16]u16 = undefined;
                @memcpy(&ww, std.mem.bytesAsSlice(
                    u16,
                    std.mem.sliceAsBytes(item.value.items),
                ));

                for (ww, 0..) |value, idx| {
                    try writer.print("WW[0x{X:0>4}] {d}\n", .{
                        idx,
                        @as(i16, @bitCast(value)),
                    });
                }
            }
        }
        if (register_wr) {
            for (track_line.register_wr.items) |item| {
                try writer.print(
                    "Line: {s}, Driver: {d}\n",
                    .{ line_name, item.driver },
                );
                var wr: [16]u16 = undefined;
                @memcpy(&wr, std.mem.bytesAsSlice(
                    u16,
                    std.mem.sliceAsBytes(item.value.items),
                ));
                for (wr, 0..) |value, idx| {
                    try writer.print("WR[0x{X:0>4}] {d}\n", .{
                        idx,
                        @as(i16, @bitCast(value)),
                    });
                }
            }
        }
    } else {
        // Structured register print
        if (register_x) {
            for (track_line.register_x.items) |item| {
                try writer.print("Line: {s}, Driver: {d}, Register: ", .{
                    line_name,
                    item.driver,
                });
                const x = std.mem.bytesAsValue(
                    registers.X,
                    std.mem.sliceAsBytes(item.value.items),
                );
                try writer.print("{f}", .{x.*});
            }
        }
        if (register_y) {
            for (track_line.register_y.items) |item| {
                try writer.print("Line: {s}, Driver: {d}, Register: ", .{
                    line_name,
                    item.driver,
                });
                const y = std.mem.bytesAsValue(
                    registers.Y,
                    std.mem.sliceAsBytes(item.value.items),
                );
                try writer.print("{f}", .{y.*});
            }
        }
        if (register_ww) {
            for (track_line.register_ww.items) |item| {
                try writer.print("Line: {s}, Driver: {d}, Register: ", .{
                    line_name,
                    item.driver,
                });
                const ww = std.mem.bytesAsValue(
                    registers.Ww,
                    std.mem.sliceAsBytes(item.value.items),
                );
                try writer.print("{f}", .{ww.*});
            }
        }
        if (register_wr) {
            for (track_line.register_wr.items) |item| {
                try writer.print("Line: {s}, Driver: {d}, Register: ", .{
                    line_name,
                    item.driver,
                });
                const wr = std.mem.bytesAsValue(
                    registers.Wr,
                    std.mem.sliceAsBytes(item.value.items),
                );
                try writer.print("{f}", .{wr.*});
            }
        }
    }
    try writer.flush();
}

test {
    std.testing.refAllDecls(@This());
}
