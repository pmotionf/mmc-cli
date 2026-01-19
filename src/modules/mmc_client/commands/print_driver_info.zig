const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_driver_info");
    defer tracy_zone.end();
    if (client.sock == null) return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    var filter: client.Filter = try .parse(params[1]);
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_driver_state = true,
                        .info_driver_errors = true,
                        .filter = filter.toProtobuf(),
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
    const driver_state = track.driver_state;
    const driver_errors = track.driver_errors;
    if (driver_state.items.len != driver_errors.items.len)
        return error.InvalidResponse;
    var stdout = std.Io.File.stdout().writer(io, &.{});
    const writer = &stdout.interface;
    for (driver_state.items, driver_errors.items) |info, err| {
        _ = try client.nestedWrite(
            "Driver state",
            info,
            0,
            writer,
        );
        _ = try client.nestedWrite(
            "Driver error",
            err,
            0,
            writer,
        );
        try writer.flush();
    }
}
