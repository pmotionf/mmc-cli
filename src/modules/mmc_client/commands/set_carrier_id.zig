const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "set_carrier_id");
    defer tracy_zone.end();
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const carrier = try std.fmt.parseUnsigned(u32, params[1], 0);
    const new_carrier = try std.fmt.parseUnsigned(u32, params[2], 0);
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
    try client.sendRequest(io, gpa, net, request);
    try client.waitCommandCompleted(io, gpa, net);
}

test {
    std.testing.refAllDecls(@This());
}
