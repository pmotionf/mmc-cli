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

            if (IsValidCodePage(65001) == 0) {
                return error.Utf8CodePageNotInstalled;
            }
            // Set input/output codepages to UTF-8
            if (console.SetConsoleOutputCP(65001) == 0) {
                return std.os.windows.unexpectedError(
                    std.os.windows.GetLastError(),
                );
            }
            if (console.SetConsoleCP(65001) == 0) {
                return std.os.windows.unexpectedError(
                    std.os.windows.GetLastError(),
                );
            }

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

pub const Color = union(enum) {
    default: void,
    named: enum {
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        bright_black,
        bright_red,
        bright_green,
        bright_yellow,
        bright_blue,
        bright_magenta,
        bright_cyan,
        bright_white,
    },
    lut: enum(u8) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
        bright_black = 8,
        bright_red = 9,
        bright_green = 10,
        bright_yellow = 11,
        bright_blue = 12,
        bright_magenta = 13,
        bright_cyan = 14,
        bright_white = 15,
        // 16 - 231 are the 216 table colors
        // 232 - 255 are grayscale colors
        _,

        /// Red, Green, and Blue values should be given in range of [0, 5].
        pub fn color(r: u3, g: u3, b: u3) @This() {
            return @enumFromInt(
                16 + 36 * @as(u8, @min(r, 5)) +
                    6 * @as(u8, @min(5, g)) +
                    @as(u8, @min(5, b)),
            );
        }

        test color {
            const lut_color = color(5, 5, 5);
            try std.testing.expectEqual(231, @intFromEnum(lut_color));
        }

        /// Grayscale step range of [0, 23] where 0 is black and 23 is white.
        pub fn grayscale(step: u5) @This() {
            return @enumFromInt(232 + @as(u8, step));
        }

        pub fn fromNamed(named: @FieldType(Color, "named")) @This() {
            return switch (named) {
                inline else => |c| @field(@This(), @tagName(c)),
            };
        }

        pub fn fromRgb(rgb: @FieldType(Color, "rgb")) @This() {
            return @enumFromInt(
                16 + 36 * (rgb.r / 51) + 6 * (rgb.g / 51) + (rgb.b / 51),
            );
        }
    },
    rgb: packed struct { r: u8, g: u8, b: u8 },
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: ?bool = null,
    underline: ?bool = null,
    /// Reverse foreground and background colors.
    reverse: ?bool = null,
};

pub const style = struct {
    pub fn set(writer: std.io.AnyWriter, s: Style) !void {
        if (s.fg) |color| {
            switch (color) {
                .default => try writer.writeAll("\x1B[39m"),
                .named => |name| try writer.print("\x1B[{d}m", .{
                    @as(u8, switch (name) {
                        .black => 30,
                        .red => 31,
                        .green => 32,
                        .yellow => 33,
                        .blue => 34,
                        .magenta => 35,
                        .cyan => 36,
                        .white => 37,
                        .bright_black => 90,
                        .bright_red => 91,
                        .bright_green => 92,
                        .bright_yellow => 93,
                        .bright_blue => 94,
                        .bright_magenta => 95,
                        .bright_cyan => 96,
                        .bright_white => 97,
                    }),
                }),
                .lut => |lut_tag| try writer.print(
                    "\x1B[38;5;{d}m",
                    .{@intFromEnum(lut_tag)},
                ),
                .rgb => |rgb_val| try writer.print(
                    "\x1B[38;2;{d};{d};{d}m",
                    .{ rgb_val.r, rgb_val.g, rgb_val.b },
                ),
            }
        }
        if (s.bg) |color| {
            switch (color) {
                .default => try writer.writeAll("\x1B[49m"),
                .named => |name| try writer.print("\x1B[{d}m", .{
                    @as(u8, switch (name) {
                        .black => 40,
                        .red => 41,
                        .green => 42,
                        .yellow => 43,
                        .blue => 44,
                        .magenta => 45,
                        .cyan => 46,
                        .white => 47,
                        .bright_black => 100,
                        .bright_red => 101,
                        .bright_green => 102,
                        .bright_yellow => 103,
                        .bright_blue => 104,
                        .bright_magenta => 105,
                        .bright_cyan => 106,
                        .bright_white => 107,
                    }),
                }),
                .lut => |lut_tag| try writer.print(
                    "\x1B[48;5;{d}m",
                    .{@intFromEnum(lut_tag)},
                ),
                .rgb => |rgb_val| try writer.print(
                    "\x1B[48;2;{d};{d};{d}m",
                    .{ rgb_val.r, rgb_val.g, rgb_val.b },
                ),
            }
        }
        if (s.bold) |bold| {
            try writer.print("\x1B[{d}m", .{@as(u8, if (bold) 1 else 22)});
        }
        if (s.underline) |ul| {
            try writer.print("\x1B[{d}m", .{@as(u8, if (ul) 4 else 24)});
        }
        if (s.reverse) |rev| {
            if (rev) {
                try writer.writeAll("\x1B[7m");
            }
        }
    }
    pub fn reset(writer: std.io.AnyWriter) !void {
        try writer.writeAll("\x1B[0m");
    }
};

pub const cursor = struct {
    /// Move cursor to provided column.
    pub fn moveColumn(writer: std.io.AnyWriter, column: usize) !void {
        try writer.print("\x1B[{d}G", .{column});
    }
};

const OriginalCanonicalContext = switch (builtin.os.tag) {
    .linux => std.os.linux.termios,
    .windows => @import("win32").system.console.CONSOLE_MODE,
    else => @compileError("unsupported OS"),
};

extern "kernel32" fn IsValidCodePage(
    cp: std.os.windows.UINT,
) callconv(.winapi) std.os.windows.BOOL;
