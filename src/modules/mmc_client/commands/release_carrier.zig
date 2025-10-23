//! This file contains client for managing the server-side state.
const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");

pub fn impl(params: [][]const u8) !void {
    const socket = client.sock orelse return error.ServerNotConnected;
    const line_name: []const u8 = params[0];
    const line_idx = try client.matchLine(line_name);
    const line = client.lines[line_idx];
    var filter: ?client.Filter = null;
    if (params[1].len > 0) {
        filter = try .parse(params[1]);
    }
    const carrier_id: ?u32 = if (filter) |*_filter| b: {
        switch (_filter.*) {
            .axis => {
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
                            .filter = _filter.toProtobuf(),
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
                const axis = track.axis_state.pop() orelse return error.InvalidResponse;
                if (axis.carrier == 0) return error.CarrierNotFound;
                break :b axis.carrier;
            },
            .carrier => |carrier_id| break :b carrier_id[0],
            .driver => {
                {
                    try client.removeIgnoredMessage(socket);
                    try socket.waitToWrite(&command.checkCommandInterrupt);
                    var writer = socket.writer(&client.writer_buf);
                    try client.api.request.info.track.encode(
                        client.allocator,
                        &writer.interface,
                        .{
                            .line = line.id,
                            .info_carrier_state = true,
                            .filter = _filter.toProtobuf(),
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
                const carriers = track.carrier_state;
                if (carriers.items.len == 0) return error.CarrierNotFound;
                for (carriers.items) |carrier| {
                    {
                        try client.removeIgnoredMessage(socket);
                        try socket.waitToWrite(&command.checkCommandInterrupt);
                        var writer = socket.writer(&client.writer_buf);
                        try client.api.request.command.release.encode(
                            client.allocator,
                            &writer.interface,
                            .{
                                .line = line.id,
                                .carrier = carrier.id,
                            },
                        );
                        try writer.interface.flush();
                    }
                    try client.waitCommandReceived();
                }
                return;
            },
        }
    } else null;
    {
        try client.removeIgnoredMessage(socket);
        try socket.waitToWrite(&command.checkCommandInterrupt);
        var writer = socket.writer(&client.writer_buf);
        try client.api.request.command.release.encode(
            client.allocator,
            &writer.interface,
            .{
                .line = line.id,
                .carrier = if (carrier_id) |carrier| carrier else null,
            },
        );
        try writer.interface.flush();
    }
    try client.waitCommandReceived();
}
