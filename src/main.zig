const builtin = @import("builtin");
const std = @import("std");
const network = @import("network");

const mmc_io = @import("io.zig");
const command = @import("command.zig");
const Prompt = @import("Prompt.zig");

// Environment variables to be used through the program, mainly locating
// configuration files.
pub var environ_map: *std.process.Environ.Map = undefined;

pub const std_options: std.Options = .{
    .logFn = command.logFn,
};

pub var exit: std.atomic.Value(bool) = .init(false);

var prompt: Prompt = .{};

fn stopCommandWindows(
    dwCtrlType: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL {
    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
        command.stop.store(true, .monotonic);
        std.Io.File.stdin().sync() catch {};
    }
    return 1;
}

fn stopCommandLinux(_: std.os.linux.SIG) callconv(.c) void {
    command.stop.store(true, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    environ_map = init.environ_map;
    try mmc_io.init();
    defer mmc_io.deinit();

    var prompter = try std.Thread.spawn(
        .{},
        Prompt.handler,
        .{ &prompt, init.io },
    );
    prompter.detach();
    defer prompt.close.store(true, .monotonic);

    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            try windows.SetConsoleCtrlHandler(&stopCommandWindows, true);
            const handle =
                try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
            var mode: windows.DWORD = 0;
            if (windows.kernel32.GetConsoleMode(
                handle,
                &mode,
            ) != windows.TRUE) {
                return error.WindowsConsoleModeRetrievalFailure;
            }
            mode |= windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if (windows.kernel32.SetConsoleMode(
                handle,
                mode,
            ) != windows.TRUE) {
                return error.WindowsConsoleModeSetFailure;
            }
        },
        .linux => {
            const linux = std.os.linux;
            const action: linux.Sigaction = .{
                .handler = .{ .handler = &stopCommandLinux },
                .mask = linux.sigemptyset(),
                .flags = 0,
            };

            if (linux.sigaction(linux.SIG.INT, &action, null) != 0) {
                return error.LinuxSignalHandlerSetFailure;
            }
        },
        else => {},
    }

    try command.init();
    defer command.deinit();

    command_loop: while (!exit.load(.monotonic)) {
        if (command.stop.load(.monotonic)) {
            command.queueClear();
            command.stop.store(false, .monotonic);
        }
        if (command.queueEmpty()) {
            prompt.disable.store(false, .monotonic);
            continue :command_loop;
        } else {
            prompt.disable.store(true, .monotonic);
        }

        command.execute(init.io) catch |e| {
            std.log.err("{t}", .{e});
            if (@errorReturnTrace()) |stack_trace| {
                std.debug.dumpStackTrace(stack_trace);
            }
            command.queueClear();
            continue :command_loop;
        };
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
