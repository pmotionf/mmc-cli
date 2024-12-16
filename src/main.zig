const builtin = @import("builtin");
const std = @import("std");
const network = @import("network");
const command = @import("command.zig");

pub const std_options: std.Options = .{
    .logFn = command.logFn,
};

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
        const windows = std.os.windows;
        try windows.SetConsoleCtrlHandler(&stopCommand, true);
        const handle = try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
        var mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(handle, &mode) != windows.TRUE) {
            return error.WindowsConsoleModeRetrievalFailure;
        }
        mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        if (windows.kernel32.SetConsoleMode(handle, mode) != windows.TRUE) {
            return error.WindowsConsoleModeSetFailure;
        }
    }

    try command.init();
    defer command.deinit();

    const stdin = std.io.getStdIn();
    var buffered_reader = std.io.bufferedReader(stdin.reader());
    const reader = buffered_reader.reader();

    command_loop: while (true) {
        if (command.stop.load(.monotonic)) {
            command.command_queue.clear();
            command.stop.store(false, .monotonic);
        }
        if (command.command_queue.isEmpty()) {
            var input_buffer: [1024]u8 = .{0} ** 1024;
            // Simulating enqueue command
            std.log.info("Please enter a command (HELP for info): ", .{});

            if (try nextLine(reader, &input_buffer)) |line| {
                const item: command.CommandQueue = command._enqueue(line);
                try command.command_queue.write(item);
            } else continue :command_loop;
        }
        if (command.command_queue.read()) |c| {
            c.parseCommand() catch |e| {
                std.log.err("{s}", .{@errorName(e)});
                std.log.debug("{any}", .{@errorReturnTrace()});
                command.command_queue.clear();
            };
            // If pointer to the next callback is not null, readd to queue.
            if (c.command_entry.execute) |_| {
                command.command_queue.write(c);
            }
        }
        // command.execute() catch |e| {
        //     std.log.err("{s}", .{@errorName(e)});
        //     std.log.debug("{any}", .{@errorReturnTrace()});
        //     command.queueClear();
        //     continue :command_loop;
        // };
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
