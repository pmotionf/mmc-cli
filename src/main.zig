const builtin = @import("builtin");
const std = @import("std");
const command = @import("command.zig");

pub const std_options: std.Options = .{
    .logFn = command.logFn,
};

fn nextLine(reader: *std.Io.Reader) !?[]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    const result = std.mem.trimEnd(u8, line, "\r");
    return result;
}

fn stopCommandLinux(_: std.os.linux.SIG) callconv(.c) void {
    command.stop.store(true, .monotonic);
}

fn stopCommandWindows(
    dwCtrlType: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL {
    if (dwCtrlType == kernel32.CTRL_C_EVENT) {
        command.stop.store(true, .monotonic);
    }
    return .fromBool(true);
}

pub fn main(init: std.process.Init) !void {
    switch (builtin.os.tag) {
        .windows => {
            const success = kernel32.SetConsoleCtrlHandler(
                &stopCommandWindows,
                .fromBool(true),
            );
            if (success.toBool() == false)
                return error.FailingSetConsoleCtrlHandler;
        },
        .linux => {
            const linux = std.os.linux;
            const action: linux.Sigaction = .{
                .handler = .{ .handler = @alignCast(&stopCommandLinux) },
                .mask = linux.sigemptyset(),
                .flags = 0,
            };

            if (linux.sigaction(linux.SIG.INT, &action, null) != 0) {
                return error.LinuxSignalHandlerSetFailure;
            }
        },
        else => @compileError("UnsupportedOS"),
    }

    const gpa = init.gpa;
    // const arena = init.arena;
    const io = init.io;

    try command.init(io, gpa);
    defer command.deinit(gpa, io);

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
            if (@errorReturnTrace()) |error_trace| {
                std.debug.dumpErrorReturnTrace(error_trace);
            }
            command.queueClear();
            continue :command_loop;
        };
    }
}

/// Windows kernel32 functions. This struct is introduced here since zig 0.16.0
/// removes support for kernel32. Only used functions and variables are
/// introduced in this struct.
const kernel32 = struct {
    pub extern "kernel32" fn SetConsoleCtrlHandler(
        HandlerRoutine: ?HANDLER_ROUTINE,
        add: std.os.windows.BOOL,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub const HANDLER_ROUTINE = *const fn (
        dwCtrlType: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    pub const CTRL_C_EVENT: std.os.windows.DWORD = 0;
};

test {
    std.testing.refAllDecls(@This());
}
