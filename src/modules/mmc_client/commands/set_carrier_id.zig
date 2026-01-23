const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "set_carrier_id");
    defer tracy_zone.end();
    const net = client.stream orelse return error.ServerNotConnected;
    var writer_buf: [4096]u8 = undefined;
    var net_writer = net.writer(io, &writer_buf);
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier = try std.fmt.parseUnsigned(u32, b: {
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
    }, 0);
    const new_carrier = try std.fmt.parseUnsigned(u32, b: {
        const input = params[2];
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
    }, 0);
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .set_carrier_id = .{
                        .line = line.id,
                        .carrier = carrier,
                        .new_carrier = new_carrier,
                    },
                },
            },
        },
    };
    // Send message
    try request.encode(&net_writer.interface, client.allocator);
    try net_writer.interface.flush();
    try client.waitCommandReceived(io);
}
