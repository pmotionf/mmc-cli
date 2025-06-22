//! This module contains the terminal input/output interface that should be
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

            // Disable auto-translate from '\r' (0x0D) to '\n' (0x0A)
            // attr.lflag.ICRNL = false;
            // Disable special Ctrl-V handling.
            attr.lflag.IEXTEN = false;
            // Disable software flow control (Ctrl-S and Ctrl-Q) handling.
            // attr.lflag.IXON = false;
            // Ensure that Ctrl-C (and Ctrl-Z) are properly sent as signals.
            attr.lflag.ISIG = true;

            // Disable canonical mode.
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

pub const event = struct {
    /// Poll for input events in the terminal.
    pub fn poll() !usize {
        switch (comptime builtin.os.tag) {
            .linux => {
                var fds: [1]std.posix.pollfd = .{.{
                    .fd = std.io.getStdIn().handle,
                    .events = std.posix.POLL.IN,
                    .revents = undefined,
                }};
                return std.posix.poll(&fds, 0);
            },
            .windows => {
                const console = @import("win32").system.console;
                var num_events: u32 = undefined;
                if (console.GetNumberOfConsoleInputEvents(
                    std.io.getStdIn().handle,
                    &num_events,
                ) == 0) {
                    return std.os.windows.unexpectedError(
                        std.os.windows.GetLastError(),
                    );
                }
                return num_events;
            },
            else => @compileError("unsupported OS"),
        }
    }

    fn readByte() !u8 {
        switch (comptime builtin.os.tag) {
            .linux => {
                const stdin = std.io.getStdIn().reader();
                return stdin.readByte();
            },
            .windows => {
                const console = @import("win32").system.console;
                var buf: [1]u8 = undefined;
                var chars_read: u32 = 0;
                if (console.ReadConsoleA(
                    std.io.getStdIn().handle,
                    &buf,
                    1,
                    &chars_read,
                    null,
                ) == 0) {
                    return std.os.windows.unexpectedError(
                        std.os.windows.GetLastError(),
                    );
                }
                if (chars_read == 0) return error.EndOfStream;
                return buf[0];
            },
            else => @compileError("unsupported OS"),
        }
    }

    fn pollByte() !bool {
        switch (comptime builtin.target.os.tag) {
            .linux => {
                var fds: [1]std.posix.pollfd = .{.{
                    .fd = std.io.getStdIn().handle,
                    .events = std.posix.POLL.IN,
                    .revents = undefined,
                }};
                return try std.posix.poll(&fds, 0) > 0;
            },
            .windows => {
                const threading = @import("win32").system.threading;
                const stdin_handle = std.io.getStdIn().handle;
                return threading.WaitForSingleObject(
                    stdin_handle,
                    0,
                ) == std.os.windows.WAIT_OBJECT_0;
            },
            else => @compileError("unsupported OS"),
        }
    }

    /// Read event from terminal input buffer.
    pub fn read(options: struct {
        /// Nanosecond timeout between bytes in a sequence. Null is instant
        /// timeout (no waiting), 0 is infinite timeout.
        sequence_timeout: ?u64 = std.time.ns_per_ms * 10,
        /// Nanosecond timeout to detect whether an escape key is pressed,
        /// versus whether it is the start of an escape sequence. 0 is instant
        /// timeout (no waiting).
        escape_timeout: u64 = std.time.ns_per_ms * 10,
    }) !Event {
        const byte = try readByte();
        const utf8_seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        var result: Event = .{ .key = undefined };

        var timer = std.time.Timer.start() catch unreachable;

        // Handle UTF-8 codepoint sequence.
        if (utf8_seq_len > 1) {
            result = .initKeyCodepointEmpty();
            result.key.value.codepoint.buffer[0] = byte;
            result.key.value.codepoint.sequence =
                result.key.value.codepoint.buffer[0..1];

            while (result.key.value.codepoint.sequence.len < utf8_seq_len) {
                if (options.sequence_timeout) |seq_timeout| {
                    if (seq_timeout == 0) {
                        result.key.value.codepoint.buffer[
                            result.key.value.codepoint.sequence.len
                        ] = try readByte();
                        result.key.value.codepoint.sequence.len += 1;
                    } else {
                        timer.reset();
                        while (timer.read() < seq_timeout) {
                            if (try pollByte()) {
                                result.key.value.codepoint.buffer[
                                    result.key.value.codepoint.sequence.len
                                ] = try readByte();
                                result.key.value.codepoint.sequence.len += 1;
                                break;
                            }
                        } else {
                            return error.IncompleteCodepoint;
                        }
                    }
                } else {
                    if (try pollByte()) {
                        result.key.value.codepoint.buffer[
                            result.key.value.codepoint.sequence.len
                        ] = try readByte();
                        result.key.value.codepoint.sequence.len += 1;
                    } else {
                        return error.IncompleteCodepoint;
                    }
                }
            }
            return result;
        }

        parse: switch (byte) {
            // Potentially escape sequence, or just Escape.
            '\x1B' => {
                if (options.escape_timeout > 0) {
                    timer.reset();
                    while (timer.read() < options.escape_timeout) {
                        if (try pollByte()) break;
                    } else {
                        result = .initKeyControl(.escape);
                        break :parse;
                    }
                } else if (!(try pollByte())) {
                    result = .initKeyControl(.escape);
                    break :parse;
                }

                // Check for '[' after escape byte
                const next = try readByte();
                if (next == '[') continue :parse '\x9B';

                var seq_buf: [escape_sequences.max_len]u8 = undefined;
                seq_buf[0] = next;
                var seq: []u8 = seq_buf[0..1];
                if (escape_sequences.get(seq)) |ev| {
                    result = ev;
                    break :parse;
                }

                if (options.sequence_timeout) |seq_timeout| {
                    if (seq_timeout == 0) {
                        while (seq.len < seq_buf.len) {
                            seq_buf[seq.len] = try readByte();
                            seq.len += 1;
                            // Eager match sequence
                            if (escape_sequences.get(seq)) |ev| {
                                result = ev;
                                break :parse;
                            }
                        }
                        if (escape_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        } else {
                            return error.UnknownEscapeSequence;
                        }
                    } else {
                        while (seq.len < seq_buf.len) {
                            timer.reset();
                            while (timer.read() < seq_timeout) {
                                if (try pollByte()) {
                                    break;
                                }
                            } else {
                                return error.IncompleteEscapeSequence;
                            }
                            seq_buf[seq.len] = try readByte();
                            seq.len += 1;
                            // Eager match sequence
                            if (escape_sequences.get(seq)) |ev| {
                                result = ev;
                                break :parse;
                            }
                        }
                        if (escape_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        } else {
                            return error.UnknownEscapeSequence;
                        }
                    }
                } else {
                    while (seq.len < seq_buf.len) {
                        if (!(try pollByte())) {
                            return error.IncompleteEscapeSequence;
                        }
                        seq_buf[seq.len] = try readByte();
                        seq.len += 1;
                        // Eager match sequence
                        if (escape_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        }
                    }
                    if (escape_sequences.get(seq)) |ev| {
                        result = ev;
                        break :parse;
                    } else {
                        return error.UnknownEscapeSequence;
                    }
                }
            },
            // CSI escape sequence.
            '\x9B' => {
                var seq_buf: [csi_sequences.max_len]u8 = undefined;
                var seq: []u8 = seq_buf[0..0];
                if (options.sequence_timeout) |seq_timeout| {
                    if (seq_timeout == 0) {
                        while (seq.len < seq_buf.len) {
                            seq_buf[seq.len] = try readByte();
                            seq.len += 1;
                            // Eager match sequence
                            if (csi_sequences.get(seq)) |ev| {
                                result = ev;
                                break :parse;
                            }
                        }
                        if (csi_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        } else {
                            return error.UnknownCsiSequence;
                        }
                    } else {
                        while (seq.len < seq_buf.len) {
                            timer.reset();
                            while (timer.read() < seq_timeout) {
                                if (try pollByte()) {
                                    break;
                                }
                            } else {
                                std.log.debug(
                                    "Incomplete CSI sequence {s}",
                                    .{seq},
                                );
                                return error.IncompleteCsiSequence;
                            }
                            seq_buf[seq.len] = try readByte();
                            seq.len += 1;
                            // Eager match sequence
                            if (csi_sequences.get(seq)) |ev| {
                                result = ev;
                                break :parse;
                            }
                        }
                        if (csi_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        } else {
                            std.log.debug(
                                "Unknown CSI sequence {s}",
                                .{seq},
                            );
                            return error.UnknownCsiSequence;
                        }
                    }
                } else {
                    while (seq.len < seq_buf.len) {
                        if (!(try pollByte())) {
                            return error.IncompleteCsiSequence;
                        }
                        seq_buf[seq.len] = try readByte();
                        seq.len += 1;
                        // Eager match sequence
                        if (csi_sequences.get(seq)) |ev| {
                            result = ev;
                            break :parse;
                        }
                    }
                    if (csi_sequences.get(seq)) |ev| {
                        result = ev;
                        break :parse;
                    } else {
                        return error.UnknownCsiSequence;
                    }
                }
            },

            '\x00' => switch (comptime builtin.os.tag) {
                .linux => {},
                .windows => {
                    result = .initKeyCodepointEmpty();
                    result.key.value.codepoint.buffer[0] = ' ';
                    result.key.value.codepoint.sequence =
                        result.key.value.codepoint.buffer[0..1];
                    result.key.modifiers.ctrl = true;
                },
                else => @compileError("unsupported OS"),
            },

            // Ctrl-A
            '\x01' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'a';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-B
            '\x02' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'b';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-C
            '\x03' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'c';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-D
            '\x04' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'd';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            '\x09' => result = .initKeyControl(.tab),
            // Ctrl-Enter
            '\x0A' => {
                result = .initKeyControl(.enter);
                result.key.modifiers.ctrl = true;
            },
            '\x0D' => result = .initKeyControl(.enter),
            // Ctrl-O
            '\x0F' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'o';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-Q
            '\x11' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'q';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-S
            '\x13' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 's';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-V
            '\x16' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'v';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-Z
            '\x1A' => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = 'z';
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
                result.key.modifiers.ctrl = true;
            },

            '\x7F' => result = .initKeyControl(.backspace),

            else => {
                result = .initKeyCodepointEmpty();
                result.key.value.codepoint.buffer[0] = byte;
                result.key.value.codepoint.sequence =
                    result.key.value.codepoint.buffer[0..1];
            },
        }
        return result;
    }
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,

    /// Initializes key event empty codepoint.
    pub fn initKeyCodepointEmpty() Event {
        return .{ .key = .{ .value = .{ .codepoint = .{} } } };
    }

    /// Initializes control key event.
    pub fn initKeyControl(ctrl: Key.Control) Event {
        return .{ .key = .{ .value = .{ .control = ctrl } } };
    }

    pub const Key = struct {
        value: union(enum) {
            codepoint: struct {
                sequence: []u8 = &.{},
                buffer: [4]u8 = undefined,
            },
            control: Control,
        },
        modifiers: packed struct {
            ctrl: bool = false,
            alt: bool = false,
            shift: bool = false,
        } = .{},

        pub const Control = enum(u21) {
            arrow_up,
            arrow_down,
            arrow_right,
            arrow_left,
            home,
            end,
            backspace,
            delete,
            insert,
            pause,
            escape,
            page_up,
            page_down,
            tab,
            enter,
        };
    };

    pub const Mouse = packed struct {
        // TODO: Support terminal mouse events. Should be done after
        // implementing incrementally detected support for Kitty protocol.
    };
};

const OriginalCanonicalContext = switch (builtin.os.tag) {
    .linux => std.os.linux.termios,
    .windows => @import("win32").system.console.CONSOLE_MODE,
    else => @compileError("unsupported OS"),
};

extern "kernel32" fn IsValidCodePage(
    cp: std.os.windows.UINT,
) callconv(.winapi) std.os.windows.BOOL;

/// Terminal input escape sequences.
const escape_sequences: std.StaticStringMap(Event) = .initComptime(
    .{
        .{ "OA", Event{ .key = .{ .value = .{ .control = .arrow_up } } } },
        .{ "OB", Event{ .key = .{ .value = .{ .control = .arrow_down } } } },
        .{ "OC", Event{ .key = .{ .value = .{ .control = .arrow_right } } } },
        .{ "OD", Event{ .key = .{ .value = .{ .control = .arrow_left } } } },
        .{ "OH", Event{ .key = .{ .value = .{ .control = .home } } } },
        .{ "OF", Event{ .key = .{ .value = .{ .control = .end } } } },
    } ++ switch (builtin.target.os.tag) {
        .windows => .{},
        .linux => .{},
        else => @compileError("unsupported OS"),
    },
);

/// Terminal input CSI sequences.
const csi_sequences: std.StaticStringMap(Event) = .initComptime(
    .{
        .{ "1~", Event{ .key = .{ .value = .{ .control = .home } } } },
        .{ "2~", Event{ .key = .{ .value = .{ .control = .insert } } } },
        .{ "3~", Event{ .key = .{ .value = .{ .control = .delete } } } },
        .{ "4~", Event{ .key = .{ .value = .{ .control = .end } } } },
        .{ "5~", Event{ .key = .{ .value = .{ .control = .page_up } } } },
        .{ "6~", Event{ .key = .{ .value = .{ .control = .page_down } } } },
        .{ "7~", Event{ .key = .{ .value = .{ .control = .home } } } },
        .{ "8~", Event{ .key = .{ .value = .{ .control = .end } } } },
        .{ "A", Event{ .key = .{ .value = .{ .control = .arrow_up } } } },
        .{ "B", Event{ .key = .{ .value = .{ .control = .arrow_down } } } },
        .{ "C", Event{ .key = .{ .value = .{ .control = .arrow_right } } } },
        .{ "D", Event{ .key = .{ .value = .{ .control = .arrow_left } } } },
        .{ "H", Event{ .key = .{ .value = .{ .control = .home } } } },
        .{ "F", Event{ .key = .{ .value = .{ .control = .end } } } },
        .{ "Z", Event{ .key = .{
            .value = .{ .control = .tab },
            .modifiers = .{ .shift = true },
        } } },
        .{ "1;5A", Event{ .key = .{
            .value = .{ .control = .arrow_up },
            .modifiers = .{ .ctrl = true },
        } } },
        .{ "1;5B", Event{ .key = .{
            .value = .{ .control = .arrow_down },
            .modifiers = .{ .ctrl = true },
        } } },
        .{ "1;5C", Event{ .key = .{
            .value = .{ .control = .arrow_right },
            .modifiers = .{ .ctrl = true },
        } } },
        .{ "1;5D", Event{ .key = .{
            .value = .{ .control = .arrow_left },
            .modifiers = .{ .ctrl = true },
        } } },
    },
);
