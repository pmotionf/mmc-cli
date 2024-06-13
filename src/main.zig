const builtin = @import("builtin");
const std = @import("std");
const network = @import("network");
const command = @import("command.zig");

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    const line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    const result = std.mem.trimRight(u8, line, "\r");
    return result;
}

fn stopCommand(
    dwCtrlType: std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
        command.stop.store(true, .monotonic);
        std.io.getStdIn().sync() catch {};
    }
    return 1;
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        try std.os.windows.SetConsoleCtrlHandler(&stopCommand, true);
    }

    try command.init();
    defer command.deinit();

    const stdin = std.io.getStdIn();
    var buffered_reader = std.io.bufferedReader(stdin.reader());
    const reader = buffered_reader.reader();

    command_loop: while (true) {
        if (command.stop.load(.monotonic)) {
            command.queueClear();
            command.stop.store(false, .monotonic);
        }
        if (command.queueEmpty()) {
            var input_buffer: [1024]u8 = .{0} ** 1024;
            std.log.info("Please enter a command (HELP for info): ", .{});

            if (try nextLine(reader, &input_buffer)) |line| {
                try command.enqueue(line);
            } else continue :command_loop;
        }
        command.execute() catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            std.log.debug("{any}", .{@errorReturnTrace()});
            command.queueClear();
            continue :command_loop;
        };
    }
}
