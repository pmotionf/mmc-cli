const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");
const CommandRequest = @FieldType(
    api.protobuf.mmc.Request.body_union,
    "command",
);

pub fn impl(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    const net = client.sock orelse return error.ServerNotConnected;
    const line_name = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    const axis_id: u32 = try std.fmt.parseInt(u32, buf: {
        const input = params[1];
        var suffix: ?usize = null;
        for (input, 0..) |c, i| if (!std.ascii.isDigit(c)) {
            // Only valid suffix for axis_id is either 'a' or "axis".
            if (c != 'a') return error.InvalidCharacter;
            suffix = i;
            break;
        };
        if (suffix) |ignore_idx| {
            if (ignore_idx == 0) return error.InvalidCharacter;
            break :buf input[0..ignore_idx];
        } else break :buf input;
    }, 0);
    const dir: CommandRequest.Direction =
        if (std.mem.eql(u8, "forward", params[2]))
            .DIRECTION_FORWARD
        else if (std.mem.eql(u8, "backward", params[2]))
            .DIRECTION_BACKWARD
        else
            return error.InvalidDirection;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .push = .{
                        .line = line.id,
                        .velocity = line.velocity,
                        .acceleration = line.acceleration,
                        .direction = dir,
                        .axis = axis_id,
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
