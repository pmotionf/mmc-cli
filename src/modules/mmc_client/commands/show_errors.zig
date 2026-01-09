const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "show_errors");
    defer tracy_zone.end();
    if (client.sock == null) return error.ServerNotConnected;
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
    _ = client.reader.interface.discardRemaining() catch {};
    _ = client.writer.interface.consumeAll();
    // Send message
    try request.encode(&client.writer.interface, client.allocator);
    try client.writer.interface.flush();
    // Receive response
    while (true) {
        try command.checkCommandInterrupt();
        const byte = client.reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (client.reader.error_state orelse error.Unexpected) {
                        else => |err| err,
                    };
                },
            }
        };
        if (byte > 0) break;
    }
    var decoded: api.protobuf.mmc.Response = try .decode(
        &client.reader.interface,
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
    var writer_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
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
