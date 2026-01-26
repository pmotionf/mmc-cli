const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "carrier_id");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    if (client.sock == null) return error.ServerNotConnected;
    var line_name_iterator = std.mem.tokenizeSequence(
        u8,
        params[0],
        ",",
    );
    const save_var: []const u8 = params[1];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;
    if (save_var.len > 32) return error.PrefixTooLong;

    // Validate line names, avoid heap allocation
    var line_counter: usize = 0;
    while (line_name_iterator.next()) |line_name| {
        if (client.matchLine(line_name)) |_| {
            line_counter += 1;
        } else |e| {
            std.log.info("Line {s} not found", .{line_name});
            return e;
        }
    }
    var line_idxs: std.ArrayList(u32) = .{};
    try line_idxs.ensureTotalCapacity(client.allocator, line_counter);
    defer line_idxs.deinit(client.allocator);
    line_name_iterator.reset();
    while (line_name_iterator.next()) |line_name| {
        try line_idxs.append(
            client.allocator,
            @intCast(try client.matchLine(line_name)),
        );
    }

    var count: usize = 1;
    var lines: std.ArrayList(u32) = .{};
    defer lines.deinit(client.allocator);
    try lines.ensureTotalCapacity(client.allocator, line_idxs.items.len);
    for (line_idxs.items) |line_idx| {
        const line = client.lines[@as(usize, @intCast(line_idx))];
        try lines.append(client.allocator, @as(u32, @intCast(line.id)));
    }
    const request: api.protobuf.mmc.Request = .{
        .body = .{
            .info = .{
                .body = .{
                    .track = .{
                        .lines = lines,
                        .info_axis_state = true,
                        .filter = null,
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
    for (track.lines.items) |track_line| {
        const line_idx: usize = blk: {
            for (client.lines, 0..) |l, i| {
                if (@as(u32, @intCast(l.id)) == track_line.line) break :blk i;
            }
            continue;
        };
        const line = client.lines[line_idx];
        const axis_state = track_line.axis_state;
        if (axis_state.items.len != line.axes) return error.InvalidResponse;
        var last_carrier: u32 = 0;
        for (axis_state.items) |axis| {
            if (axis.carrier == 0 or last_carrier == axis.carrier) continue;
            std.log.info(
                "Carrier {d} on Line {s} Axis {d}",
                .{ axis.carrier, line.name, axis.id },
            );
            if (save_var.len > 0) {
                var int_buf: [8]u8 = undefined;
                var var_buf: [40]u8 = undefined;
                const key = try std.fmt.bufPrint(
                    &var_buf,
                    "{s}{d}",
                    .{ save_var, count },
                );
                const value = try std.fmt.bufPrint(
                    &int_buf,
                    "{d}c",
                    .{axis.carrier},
                );
                try command.variables.put(key, value);
                count += 1;
            }
            last_carrier = axis.carrier;
        }
    }
}
