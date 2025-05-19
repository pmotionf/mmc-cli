//! This module contains the terminal input/outpt interface that should be
//! used across the program.
const builtin = @import("builtin");
const std = @import("std");

var original_canonical_context: OriginalCanonicalContext = undefined;

/// Runs necessary setup for terminal IO. Must be called exactly once before
/// any other IO function.
pub fn init() !void {
    switch (comptime builtin.os.tag) {
        .linux => {
            const stdin = std.io.getStdIn().handle;
            var attr = try std.posix.tcgetattr(stdin);
            original_canonical_context = attr;

            attr.lflag.ICANON = false;
            attr.lflag.ECHO = false;
            try std.posix.tcsetattr(stdin, .NOW, attr);
        },
        .windows => {
            const console = @import("win32").system.console;
            const stdin = std.io.getStdIn().handle;
            var mode: console.CONSOLE_MODE = undefined;
            if (console.GetConsoleMode(stdin, &mode) == 0) {
                return std.os.windows.unexpectedError(
                    std.os.windows.GetLastError(),
                );
            }
            original_canonical_context = mode;

            mode.ENABLE_LINE_INPUT = 0;
            mode.ENABLE_ECHO_INPUT = 0;
            mode.ENABLE_VIRTUAL_TERMINAL_INPUT = 1;
            mode.ENABLE_MOUSE_INPUT = 0;
            if (console.SetConsoleMode(stdin, mode) == 0) {
                return std.os.windows.unexpectedError(
                    std.os.windows.GetLastError(),
                );
            }
        },
        else => @compileError("unsupported OS"),
    }
}

/// Runs necessary cleanup and restoration of original terminal IO. Must be
/// called exactly once at end of program.
pub fn deinit() void {
    switch (comptime builtin.os.tag) {
        .linux => {
            const stdin = std.io.getStdIn().handle;
            std.posix.tcsetattr(
                stdin,
                .NOW,
                original_canonical_context,
            ) catch {};
        },
        .windows => {
            const console = @import("win32").system.console;
            const stdin = std.io.getStdIn().handle;
            _ = console.SetConsoleMode(stdin, original_canonical_context);
        },
        else => @compileError("unsupported OS"),
    }
}

const OriginalCanonicalContext = switch (builtin.os.tag) {
    .linux => std.os.linux.termios,
    .windows => @import("win32").system.console.CONSOLE_MODE,
    else => @compileError("unsupported OS"),
};
