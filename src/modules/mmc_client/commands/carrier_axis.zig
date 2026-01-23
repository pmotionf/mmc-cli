const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "carrier_axis");
    defer tracy_zone.end();
    const net = client.stream orelse return error.ServerNotConnected;
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var net_reader = net.reader(io, &reader_buf);
    var net_writer = net.writer(io, &writer_buf);
    const line_name: []const u8 = params[0];
    var ids = [1]u32{try std.fmt.parseInt(u32, b: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for carrier id is either 'c' or "carrier".
            if (c != 'c') return error.InvalidCharacter;
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :b input[0..ignore_idx];
        } else break :b input;
    }, 0)};
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .line = line.id,
                        .info_carrier_state = true,
                        .filter = .{
                            .carriers = .{ .ids = .fromOwnedSlice(&ids) },
                        },
                    },
                },
            },
        },
    };
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    // Receive message
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
    var proto_reader: std.Io.Reader = .fixed(net_reader.interface.buffered());
    var decoded: api.protobuf.mmc.Response = try .decode(
        &proto_reader,
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
    if (carriers.items.len > 1) return error.InvalidResponse;
    for (carriers.items) |carrier| {
        std.log.info(
            "Carrier {d} Axis: {}",
            .{ carrier.id, carrier.axis_main },
        );
        if (carrier.axis_auxiliary) |aux|
            std.log.info("Carrier {d} Axis: {}", .{ carrier.id, aux });
    }
}
