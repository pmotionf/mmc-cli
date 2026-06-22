const builtin = @import("builtin");
const std = @import("std");
const command = @import("command.zig");

pub const std_options: std.Options = .{
    .logFn = command.logFn,
};

fn nextLine(reader: *std.Io.Reader) !?[]const u8 {
    const line = reader.takeDelimiterExclusive('\n') catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return e,
    };
    const result = std.mem.trimEnd(u8, line, "\r");
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

pub fn main(init: std.process.Init) !void {
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

    const gpa = init.gpa;
    // const arena = init.arena;
    const io = init.io;

    try command.init(io, gpa);
    defer command.deinit(gpa);

    const stdin = std.Io.File.stdin();
    var stdin_buf: [1024]u8 = undefined;
    var file_reader = stdin.reader(io, &stdin_buf);
    const reader = &file_reader.interface;

    command_loop: while (true) {
        if (command.stop.load(.monotonic)) {
            command.queueClear();
            command.stop.store(false, .monotonic);
        }
        if (command.queueEmpty()) {
            std.log.info("Please enter a command (HELP for info): ", .{});

            if (try nextLine(reader)) |line| {
                try command.enqueue(gpa, line);
            } else continue :command_loop;
        }
        command.execute(io, gpa) catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            std.log.debug("{any}", .{@errorReturnTrace()});
            command.queueClear();
            continue :command_loop;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
}
