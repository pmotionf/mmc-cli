const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "show_errors");
    defer tracy_zone.end();
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_axis_errors = true,
                        .info_driver_errors = true,
                        .filter = if (filter) |*_filter|
                            _filter.toProtobuf()
                        else
                            null,
                    },
                },
            },
        },
    };
    // Clear all buffer in reader and writer for safety.
    _ = net_reader.interface.discardRemaining() catch {};
    _ = net_writer.interface.consumeAll();
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    // Receive response
    while (true) {
        try command.checkCommandInterrupt();
        const byte = net_reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (net_reader.err orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
    var decoded: api.protobuf.mmc.Response = try .decode(
        &net_reader.interface,
        client.allocator,
    );
    defer decoded.deinit(client.allocator);
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
    if (track.line != line.id) return error.InvalidResponse;
    const axis_errors = track.axis_errors;
    const driver_errors = track.driver_errors;
    var stdout = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout.interface;
    for (axis_errors.items) |err| {
        const ti = @typeInfo(@TypeOf(err)).@"struct";
        inline for (ti.fields) |field| {
            switch (@typeInfo(field.type)) {
                .bool => {
                    if (@field(err, field.name))
                        try writer.print(
                            "{s} on Axis {d}\n",
                            .{ field.name, err.id },
                        );
                },
                else => {},
            }
        }
        try writer.flush();
    }
    for (driver_errors.items) |err| {
        const ti = @typeInfo(@TypeOf(err)).@"struct";
        inline for (ti.fields) |field| {
            switch (@typeInfo(field.type)) {
                .bool => {
                    if (@field(err, field.name))
                        try writer.print(
                            "{s} on Driver {d}\n",
                            .{ field.name, err.id },
                        );
                },
                else => {},
            }
        }
        try writer.flush();
    }
}
