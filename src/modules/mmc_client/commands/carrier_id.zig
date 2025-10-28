const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
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

    var line_idxs: std.ArrayList(usize) = .empty;
    defer line_idxs.deinit(client.allocator);
    line_name_iterator.reset();
    while (line_name_iterator.next()) |line_name| {
        try line_idxs.append(client.allocator, try client.matchLine(line_name));
    }

    var count: usize = 1;
    for (line_idxs.items) |line_idx| {
        const line = client.lines[line_idx];
        {
            try client.removeIgnoredMessage(socket);
            try socket.waitToWrite(&command.checkCommandInterrupt);
            var writer = socket.writer(&client.writer_buf);
            try client.api.request.info.track.encode(
                client.allocator,
                &writer.interface,
                .{
                    .line = line.id,
                    .info_axis_state = true,
                    .filter = null,
                },
            );
            try writer.interface.flush();
        }
        try socket.waitToRead(&command.checkCommandInterrupt);
        var reader = socket.reader(&client.reader_buf);
        var track = try client.api.response.info.track.decode(
            client.allocator,
            &reader.interface,
        );
        defer track.deinit(client.allocator);
        if (track.line != line.id) return error.InvalidResponse;
        const axis_state = track.axis_state;
        if (axis_state.items.len != line.axes) return error.InvalidResponse;
        var last_carrier: u32 = 0;
        for (axis_state.items) |axis| {
            if (axis.carrier == 0 or last_carrier == axis.carrier) continue;
            std.log.info(
                "Carrier {d} on line {s} axis {d}",
                .{ axis.carrier, line.name, axis.id },
            );
            if (save_var.len > 0) {
                var int_buf: [8]u8 = undefined;
                var var_buf: [40]u8 = undefined;
                const key = try std.fmt.bufPrint(
                    &var_buf,
                    "{s}_{d}",
                    .{ save_var, count },
                );
                const value = try std.fmt.bufPrint(
                    &int_buf,
                    "{d}",
                    .{axis.carrier},
                );
                try command.variables.put(key, value);
                count += 1;
            }
            last_carrier = axis.carrier;
        }
    }
}
