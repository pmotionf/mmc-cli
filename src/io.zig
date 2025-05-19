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
        .windows => {},
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
        .windows => {},
        else => @compileError("unsupported OS"),
    }
}

const OriginalCanonicalContext = switch (builtin.os.tag) {
    .linux => std.os.linux.termios,
    .windows => {},
    else => @compileError("unsupported OS"),
};
