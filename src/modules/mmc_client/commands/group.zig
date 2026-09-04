const group = @This();

const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const move = @import("move.zig");
const api = @import("mmc-api");
const CommandRequest = @FieldType(
    api.protobuf.mmc.Request.body_union,
    "command",
);

pub fn impl(io: std.Io, gpa: std.mem.Allocator) !void {
    const net = client.sock orelse return error.ServerNotConnected;
    var commands: std.ArrayList(CommandRequest.CommandGroup) = .empty;
    defer commands.deinit(gpa);
    errdefer {
        while (command.group.popFront()) |item| {
            item.deinit(gpa);
        }
    }
    if (command.group.len == 0) return;
    while (command.group.popFront()) |item| {
        defer item.deinit(gpa);
        const params = item.params;
        if (std.mem.eql(u8, "MOVE_CARRIER", item.executable.name)) {
            const line_name = params[0];
            const line_idx = try client.matchLine(line_name);
            const line = client.lines[line_idx];
            const carrier_id: u10 = try std.fmt.parseInt(u10, b: {
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
            const target = try move.parseTarget(params[2]);
            const control: api.protobuf.mmc.Control =
                if (params[3].len == 0 or std.mem.eql(u8, "position", params[3]))
                    .CONTROL_POSITION
                else if (std.mem.eql(u8, "speed", params[3]))
                    .CONTROL_VELOCITY
                else
                    return error.InvalidControlMode;
            try commands.append(gpa, .{
                .command = .{
                    .move = .{
                        .line = line.id,
                        .carrier = carrier_id,
                        .velocity = line.velocity,
                        .acceleration = line.acceleration,
                        .target = target,
                        .control = control,
                    },
                },
            });
        } else if (std.mem.eql(u8, "PUSH_CARRIER", item.executable.name)) {
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
            // Push command request
            try commands.append(gpa, .{
                .command = .{
                    .push = .{
                        .line = line.id,
                        .velocity = line.velocity,
                        .acceleration = line.acceleration,
                        .direction = dir,
                        .axis = axis_id,
                    },
                },
            });
        } else return error.InvalidGroupedCommand;
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .group = .{
                        .commands = commands,
                    },
                },
            },
        },
    };
    try client.sendRequest(io, gpa, net, request);
    try client.waitCommandCompleted(io, gpa, net);
}
