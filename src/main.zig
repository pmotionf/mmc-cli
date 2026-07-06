const builtin = @import("builtin");
const std = @import("std");
const network = @import("network");

const terminal = @import("terminal.zig");
const command = @import("command.zig");
const Prompt = @import("Prompt.zig");

pub const std_options: std.Options = .{
    .logFn = command.logFn,
};

pub var exit: std.atomic.Value(bool) = .init(false);

var prompt: Prompt = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const map = init.environ_map;
    try terminal.init();
    defer terminal.deinit();

    var prompter = try std.Thread.spawn(
        .{},
        Prompt.handler,
        .{ io, &prompt },
    );
    prompter.detach();
    defer prompt.close.store(true, .monotonic);

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
        else => @compileError("UnsupportedOs"),
    }

    try command.init(gpa, map);
    defer command.deinit(gpa, io);

    command_loop: while (!exit.load(.monotonic)) {
        command.checkCommandInterrupt(io) catch |e| std.log.err("{t}", .{e});
        if (try command.queueEmpty(io)) {
            prompt.disable.store(false, .monotonic);
            continue :command_loop;
        } else {
            prompt.disable.store(true, .monotonic);
        }

        command.execute(gpa, io) catch |e| {
            std.log.err("{t}", .{e});
            if (@errorReturnTrace()) |error_trace| {
                std.debug.dumpErrorReturnTrace(error_trace);
            }
            try command.queueClear(io);
            continue :command_loop;
        };
    }
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
