const std = @import("std");
const client = @import("../../mmc_client.zig");
const command = @import("../../../command.zig");
const tracy = @import("tracy");
const api = @import("mmc-api");

const Standard = client.Standard;
const standard: Standard = .{};

pub fn impl(params: [][]const u8) !void {
    const tracy_zone = tracy.traceNamed(@src(), "carrier_location");
    defer tracy_zone.end();
    errdefer client.log.stop.store(true, .monotonic);
    const net = client.sock orelse return error.ServerNotConnected;
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
    const save_var: []const u8 = params[2];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;
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
    try client.sendRequest(client.allocator, net, request);
    var decoded = try client.getResponse(client.allocator, net);
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
            "Carrier {d} location: {d} {s}",
            .{
                carrier.id,
                carrier.position * 1000.0,
                standard.length.unit_short,
            },
        );
        if (save_var.len > 0) {
            var float_buf: [12]u8 = undefined;
            try command.variables.put(save_var, try std.fmt.bufPrint(
                &float_buf,
                "{d}",
                .{carrier.position},
            ));
        }
    }
}
