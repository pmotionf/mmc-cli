const std = @import("std");
const client = @import("../../mmc_client.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

const InfoRequest = @FieldType(
    api.protobuf.mmc.Request.body_union,
    "info",
);

const Register = InfoRequest.Track.Register;

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_register");
    defer tracy_zone.end();

    const net = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    var filter: client.Filter = try .parse(params[1]);

    const register: Register =
        if (std.ascii.eqlIgnoreCase(params[2], "x"))
            .REGISTER_X
        else if (std.ascii.eqlIgnoreCase(params[2], "y"))
            .REGISTER_Y
        else if (std.ascii.eqlIgnoreCase(params[2], "wr"))
            .REGISTER_WR
        else if (std.ascii.eqlIgnoreCase(params[2], "ww"))
            .REGISTER_WW
        else
            return error.InvalidParameter;

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
                        .register = register,
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
    switch (register) {
        .REGISTER_X, .REGISTER_Y => {
            for (track_line.register_values.items) |item| {
                try writer.print("{s}[0x{X:0>4}] {d}\n", .{
                    params[2],
                    item.address,
                    item.value,
                });
            }
        },
        .REGISTER_WW, .REGISTER_WR => {
            for (track_line.register_values.items) |item| {
                try writer.print("{s}[0x{X:0>4}] {d}\n", .{
                    params[2],
                    item.address,
                    @as(i16, @bitCast(@as(u16, @truncate(item.value)))),
                });
            }
        },
        else => unreachable,
    }
    try writer.flush();
}

test {
    std.testing.refAllDecls(@This());
}
