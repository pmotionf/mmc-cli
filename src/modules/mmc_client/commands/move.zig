const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "move_carrier");
    defer tracy_zone.end();
    if (client.sock == null) return error.ServerNotConnected;
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
    const target = try parseTarget(params[2]);
    const control: api.protobuf.mmc.Control =
        if (params[4].len == 0 or std.mem.eql(u8, "position", params[3]))
            .CONTROL_POSITION
        else if (std.mem.eql(u8, "speed", params[3]))
            .CONTROL_VELOCITY
        else
            return error.InvalidControlMode;
    const disable_cas = if (params[3].len == 0)
        false
    else if (std.ascii.eqlIgnoreCase("on", params[4]))
        false
    else if (std.ascii.eqlIgnoreCase("off", params[4]))
        true
    else
        return error.InvalidCasConfiguration;
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .command = .{
                .body = .{
                    .move = .{
                        .line = line.id,
                        .carrier = carrier_id,
                        .velocity = line.velocity.value,
                        .velocity_mode = if (line.velocity.low)
                            .VELOCITY_MODE_LOW
                        else
                            .VELOCITY_MODE_NORMAL,
                        .acceleration = line.acceleration,
                        .target = target,
                        .disable_cas = disable_cas,
                        .control = control,
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
    try client.waitCommandReceived();
}

fn parseTarget(
    param: []const u8,
) !api.protobuf.mmc.command.Request.Move.target_union {
    var suffix_idx: usize = 0;
    for (param) |c| {
        if (std.ascii.isAlphabetic(c)) break else suffix_idx += 1;
    }
    // No digit is recognized.
    if (suffix_idx == 0) return error.InvalidParameter;
    // Check for single character suffix.
    if (param.len - suffix_idx == 1) {
        if (std.ascii.eqlIgnoreCase(param[suffix_idx..], "a")) {
            return .{
                .axis = try std.fmt.parseUnsigned(
                    u32,
                    param[0..suffix_idx],
                    0,
                ),
            };
        } else if (std.ascii.eqlIgnoreCase(param[suffix_idx..], "l")) {
            return .{
                .location = try std.fmt.parseFloat(
                    f32,
                    param[0..suffix_idx],
                ) / 1000.0,
            };
        } else if (std.ascii.eqlIgnoreCase(param[suffix_idx..], "d")) {
            return .{
                .distance = try std.fmt.parseFloat(
                    f32,
                    param[0..suffix_idx],
                ) / 1000.0,
            };
        }
    }
    // Check for `axis` suffix
    else if (param.len - suffix_idx == 4 and
        std.ascii.eqlIgnoreCase(param[suffix_idx..], "axis"))
    {
        return .{
            .axis = try std.fmt.parseUnsigned(
                u32,
                param[0..suffix_idx],
                0,
            ),
        };
    }
    // Check for `location` suffix
    else if (param.len - suffix_idx == 8 and
        std.ascii.eqlIgnoreCase(param[suffix_idx..], "location"))
    {
        return .{
            .location = try std.fmt.parseFloat(
                f32,
                param[0..suffix_idx],
            ) / 1000.0,
        };
    }
    // Check for `distance` suffix
    else if (std.ascii.eqlIgnoreCase(param[suffix_idx..], "distance")) {
        return .{
            .distance = try std.fmt.parseFloat(
                f32,
                param[0..suffix_idx],
            ) / 1000.0,
        };
    }
    return error.InvalidTarget;
}

test parseTarget {
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .axis = 1 },
        try parseTarget("1a"),
    );
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .axis = 1 },
        try parseTarget("1axis"),
    );
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .location = 0.1 },
        try parseTarget("100l"),
    );
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .location = 0.1 },
        try parseTarget("100location"),
    );
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .distance = 0.1 },
        try parseTarget("100d"),
    );
    try std.testing.expectEqual(
        api.protobuf.mmc.command.Request.Move.target_union{ .distance = 0.1 },
        try parseTarget("100distance"),
    );
    try std.testing.expectError(
        std.fmt.ParseIntError.InvalidCharacter,
        parseTarget("1.0a"),
    );
    try std.testing.expectError(error.InvalidTarget, parseTarget("1.0axi"));
}
