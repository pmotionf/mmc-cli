const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "print_carrier_info");
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
                        .info_carrier_state = true,
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
        const byte = client.reader.interface.peekByte() catch |e| {
            switch (e) {
                std.Io.Reader.Error.EndOfStream => continue,
                std.Io.Reader.Error.ReadFailed => {
                    return switch (client.reader.error_state orelse error.Unexpected) {
                        else => |err| return err,
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
    const carriers = track.carrier_state;
    if (carriers.items.len == 0) return error.CarrierNotFound;
    var writer_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
    const writer = &stdout.interface;
    for (carriers.items) |carrier| {
        _ = try client.nestedWrite("Carrier state", carrier, 0, writer);
        try writer.flush();
    }
}
