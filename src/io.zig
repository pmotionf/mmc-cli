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
            mode.ENABLE_WINDOW_INPUT = 0;
            // Necessary to have terminal handle Ctrl-C.
            mode.ENABLE_PROCESSED_INPUT = 1;
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
    italic: ?bool = null,
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
        if (s.italic) |il| {
            try writer.print("\x1B[{d}m", .{@as(u8, if (il) 3 else 23)});
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

pub const clipboard = struct {
    pub fn get(buffer: []u8) ![]u8 {
        switch (comptime builtin.os.tag) {
            .windows => {
                const win32 = @import("win32").system;
                const de = win32.data_exchange;
                const ss = win32.system_services;
                const mem = win32.memory;
                if (de.OpenClipboard(null) != 0) {
                    defer _ = de.CloseClipboard();
                    if (de.IsClipboardFormatAvailable(
                        @intFromEnum(ss.CF_UNICODETEXT),
                    ) != 0) {
                        const cp_handle = de.GetClipboardData(
                            @intFromEnum(ss.CF_UNICODETEXT),
                        );
                        if (cp_handle) |handle| {
                            if (mem.GlobalLock(
                                @bitCast(@intFromPtr(handle)),
                            )) |data| {
                                defer _ = mem.GlobalUnlock(
                                    @bitCast(@intFromPtr(handle)),
                                );
                                const wtf16: [*:0]u16 =
                                    @alignCast(@ptrCast(data));
                                const source_len = std.mem.len(wtf16);

                                const source = wtf16[0..source_len];
                                const len =
                                    std.unicode.wtf16LeToWtf8(buffer, source);
                                return buffer[0..len];
                            }
                        }
                    }
                }
            },
            else => {},
        }
        return &.{};
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
            result = .initKeyCodepoint(&.{byte});

            while (result.key.value.codepoint.len < utf8_seq_len) {
                // Windows events emit the UTF-8 sequence such that only the
                // start byte has a corresponding event in queue; poll calls
                // will not reflect the subsequent available bytes. All poll
                // calls must thus be skipped for UTF-8 sequence parsing.
                if (comptime builtin.os.tag == .windows) {
                    result.key.value.codepoint.buffer[
                        result.key.value.codepoint.len
                    ] = try readByte();
                    result.key.value.codepoint.len += 1;
                } else {
                    if (options.sequence_timeout) |seq_timeout| {
                        if (seq_timeout == 0) {
                            result.key.value.codepoint.buffer[
                                result.key.value.codepoint.len
                            ] = try readByte();
                            result.key.value.codepoint.len += 1;
                        } else {
                            timer.reset();
                            while (timer.read() < seq_timeout) {
                                if (try pollByte()) {
                                    result.key.value.codepoint.buffer[
                                        result.key.value.codepoint.len
                                    ] = try readByte();
                                    result.key.value.codepoint.len += 1;
                                    break;
                                }
                            } else {
                                return error.IncompleteCodepoint;
                            }
                        }
                    } else {
                        if (try pollByte()) {
                            result.key.value.codepoint.buffer[
                                result.key.value.codepoint.len
                            ] = try readByte();
                            result.key.value.codepoint.len += 1;
                        } else {
                            return error.IncompleteCodepoint;
                        }
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

            '\x00' => {
                result = .initKeyCodepoint(" ");
                result.key.modifiers.ctrl = true;
            },

            '\x01' => {
                result = .initKeyCodepoint("a");
                result.key.modifiers.ctrl = true;
            },
            '\x02' => {
                result = .initKeyCodepoint("b");
                result.key.modifiers.ctrl = true;
            },
            '\x03' => {
                result = .initKeyCodepoint("c");
                result.key.modifiers.ctrl = true;
            },
            '\x04' => {
                result = .initKeyCodepoint("d");
                result.key.modifiers.ctrl = true;
            },
            '\x05' => {
                result = .initKeyCodepoint("e");
                result.key.modifiers.ctrl = true;
            },
            '\x06' => {
                result = .initKeyCodepoint("f");
                result.key.modifiers.ctrl = true;
            },
            '\x07' => {
                result = .initKeyCodepoint("g");
                result.key.modifiers.ctrl = true;
            },
            '\x08' => {
                result = .initKeyControl(.backspace);
                result.key.modifiers.ctrl = true;
            },
            '\x09' => result = .initKeyControl(.tab),
            '\x0A' => {
                result = .initKeyControl(.enter);
                result.key.modifiers.ctrl = true;
            },
            '\x0B' => {
                result = .initKeyCodepoint("k");
                result.key.modifiers.ctrl = true;
            },
            '\x0C' => {
                result = .initKeyCodepoint("l");
                result.key.modifiers.ctrl = true;
            },
            '\x0D' => result = .initKeyControl(.enter),
            '\x0E' => {
                result = .initKeyCodepoint("n");
                result.key.modifiers.ctrl = true;
            },
            '\x0F' => {
                result = .initKeyCodepoint("o");
                result.key.modifiers.ctrl = true;
            },
            '\x10' => {
                result = .initKeyCodepoint("p");
                result.key.modifiers.ctrl = true;
            },
            '\x11' => {
                result = .initKeyCodepoint("q");
                result.key.modifiers.ctrl = true;
            },
            '\x12' => {
                result = .initKeyCodepoint("r");
                result.key.modifiers.ctrl = true;
            },
            '\x13' => {
                result = .initKeyCodepoint("s");
                result.key.modifiers.ctrl = true;
            },
            '\x14' => {
                result = .initKeyCodepoint("t");
                result.key.modifiers.ctrl = true;
            },
            '\x15' => {
                result = .initKeyCodepoint("u");
                result.key.modifiers.ctrl = true;
            },
            '\x16' => {
                result = .initKeyCodepoint("v");
                result.key.modifiers.ctrl = true;
            },
            '\x17' => {
                result = .initKeyCodepoint("w");
                result.key.modifiers.ctrl = true;
            },
            '\x18' => {
                result = .initKeyCodepoint("x");
                result.key.modifiers.ctrl = true;
            },
            // Ctrl-Y
            '\x19' => {
                result = .initKeyCodepoint("y");
                result.key.modifiers.ctrl = true;
            },
            '\x1A' => {
                result = .initKeyCodepoint("z");
                result.key.modifiers.ctrl = true;
            },

            '\x1C' => {
                result = .initKeyCodepoint("4");
                result.key.modifiers.ctrl = true;
            },
            '\x1D' => {
                result = .initKeyCodepoint("5");
                result.key.modifiers.ctrl = true;
            },
            '\x1E' => {
                result = .initKeyCodepoint("6");
                result.key.modifiers.ctrl = true;
            },
            '\x1F' => {
                result = .initKeyCodepoint("7");
                result.key.modifiers.ctrl = true;
            },

            '\x7F' => result = .initKeyControl(.backspace),

            else => {
                if (utf8_seq_len == 1) {
                    result = .initKeyCodepoint(&.{byte});
                }
            },
        }
        return result;
    }
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,

    /// Initializes key event to provided codepoint. Codepoint must be a byte
    /// sequence between length 0 and 4.
    pub fn initKeyCodepoint(codepoint: []const u8) Event {
        return .{ .key = .{ .value = .{ .codepoint = .init(codepoint) } } };
    }

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
                buffer: [4]u8 = undefined,
                len: u3 = 0,

                /// Initialize valid UTF-8 codepoint.
                pub fn init(codepoint: []const u8) @This() {
                    std.debug.assert(codepoint.len <= 4);
                    var result: @This() = undefined;
                    @memcpy(result.buffer[0..codepoint.len], codepoint);
                    result.len = @intCast(codepoint.len);
                    return result;
                }

                pub fn sequence(self: *const @This()) []const u8 {
                    return self.buffer[0..self.len];
                }
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
const escape_sequences: std.StaticStringMap(Event) = .initComptime(.{
    .{ "OA", Event{ .key = .{ .value = .{ .control = .arrow_up } } } },
    .{ "OB", Event{ .key = .{ .value = .{ .control = .arrow_down } } } },
    .{ "OC", Event{ .key = .{ .value = .{ .control = .arrow_right } } } },
    .{ "OD", Event{ .key = .{ .value = .{ .control = .arrow_left } } } },
    .{ "OH", Event{ .key = .{ .value = .{ .control = .home } } } },
    .{ "OF", Event{ .key = .{ .value = .{ .control = .end } } } },
    .{ "A", Event{ .key = .{
        .value = .{ .codepoint = .init("A") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "B", Event{ .key = .{
        .value = .{ .codepoint = .init("B") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "C", Event{ .key = .{
        .value = .{ .codepoint = .init("C") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "D", Event{ .key = .{
        .value = .{ .codepoint = .init("D") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "E", Event{ .key = .{
        .value = .{ .codepoint = .init("E") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "F", Event{ .key = .{
        .value = .{ .codepoint = .init("F") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "G", Event{ .key = .{
        .value = .{ .codepoint = .init("G") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "H", Event{ .key = .{
        .value = .{ .codepoint = .init("H") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "G", Event{ .key = .{
        .value = .{ .codepoint = .init("G") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "H", Event{ .key = .{
        .value = .{ .codepoint = .init("H") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "I", Event{ .key = .{
        .value = .{ .codepoint = .init("I") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "J", Event{ .key = .{
        .value = .{ .codepoint = .init("J") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "K", Event{ .key = .{
        .value = .{ .codepoint = .init("K") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "L", Event{ .key = .{
        .value = .{ .codepoint = .init("L") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "M", Event{ .key = .{
        .value = .{ .codepoint = .init("M") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "N", Event{ .key = .{
        .value = .{ .codepoint = .init("N") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "O", Event{ .key = .{
        .value = .{ .codepoint = .init("O") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "P", Event{ .key = .{
        .value = .{ .codepoint = .init("P") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "Q", Event{ .key = .{
        .value = .{ .codepoint = .init("Q") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "R", Event{ .key = .{
        .value = .{ .codepoint = .init("R") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "S", Event{ .key = .{
        .value = .{ .codepoint = .init("S") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "T", Event{ .key = .{
        .value = .{ .codepoint = .init("T") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "U", Event{ .key = .{
        .value = .{ .codepoint = .init("U") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "V", Event{ .key = .{
        .value = .{ .codepoint = .init("V") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "W", Event{ .key = .{
        .value = .{ .codepoint = .init("W") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "X", Event{ .key = .{
        .value = .{ .codepoint = .init("X") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "Y", Event{ .key = .{
        .value = .{ .codepoint = .init("Y") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "Z", Event{ .key = .{
        .value = .{ .codepoint = .init("Z") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "a", Event{ .key = .{
        .value = .{ .codepoint = .init("a") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "b", Event{ .key = .{
        .value = .{ .codepoint = .init("b") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "c", Event{ .key = .{
        .value = .{ .codepoint = .init("c") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "d", Event{ .key = .{
        .value = .{ .codepoint = .init("d") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "e", Event{ .key = .{
        .value = .{ .codepoint = .init("e") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "f", Event{ .key = .{
        .value = .{ .codepoint = .init("f") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "g", Event{ .key = .{
        .value = .{ .codepoint = .init("g") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "h", Event{ .key = .{
        .value = .{ .codepoint = .init("h") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "i", Event{ .key = .{
        .value = .{ .codepoint = .init("i") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "j", Event{ .key = .{
        .value = .{ .codepoint = .init("j") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "k", Event{ .key = .{
        .value = .{ .codepoint = .init("k") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "l", Event{ .key = .{
        .value = .{ .codepoint = .init("l") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "m", Event{ .key = .{
        .value = .{ .codepoint = .init("m") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "n", Event{ .key = .{
        .value = .{ .codepoint = .init("n") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "o", Event{ .key = .{
        .value = .{ .codepoint = .init("o") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "p", Event{ .key = .{
        .value = .{ .codepoint = .init("p") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "q", Event{ .key = .{
        .value = .{ .codepoint = .init("q") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "r", Event{ .key = .{
        .value = .{ .codepoint = .init("r") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "s", Event{ .key = .{
        .value = .{ .codepoint = .init("s") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "t", Event{ .key = .{
        .value = .{ .codepoint = .init("t") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "u", Event{ .key = .{
        .value = .{ .codepoint = .init("u") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "v", Event{ .key = .{
        .value = .{ .codepoint = .init("v") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "w", Event{ .key = .{
        .value = .{ .codepoint = .init("w") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "x", Event{ .key = .{
        .value = .{ .codepoint = .init("x") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "y", Event{ .key = .{
        .value = .{ .codepoint = .init("y") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "z", Event{ .key = .{
        .value = .{ .codepoint = .init("z") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "1", Event{ .key = .{
        .value = .{ .codepoint = .init("1") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "2", Event{ .key = .{
        .value = .{ .codepoint = .init("2") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "3", Event{ .key = .{
        .value = .{ .codepoint = .init("3") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "4", Event{ .key = .{
        .value = .{ .codepoint = .init("4") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "5", Event{ .key = .{
        .value = .{ .codepoint = .init("5") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "6", Event{ .key = .{
        .value = .{ .codepoint = .init("6") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "7", Event{ .key = .{
        .value = .{ .codepoint = .init("7") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "8", Event{ .key = .{
        .value = .{ .codepoint = .init("8") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "9", Event{ .key = .{
        .value = .{ .codepoint = .init("9") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "0", Event{ .key = .{
        .value = .{ .codepoint = .init("0") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "-", Event{ .key = .{
        .value = .{ .codepoint = .init("-") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "_", Event{ .key = .{
        .value = .{ .codepoint = .init("_") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "=", Event{ .key = .{
        .value = .{ .codepoint = .init("=") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "+", Event{ .key = .{
        .value = .{ .codepoint = .init("+") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "!", Event{ .key = .{
        .value = .{ .codepoint = .init("!") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "@", Event{ .key = .{
        .value = .{ .codepoint = .init("@") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "#", Event{ .key = .{
        .value = .{ .codepoint = .init("#") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "$", Event{ .key = .{
        .value = .{ .codepoint = .init("$") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "%", Event{ .key = .{
        .value = .{ .codepoint = .init("%") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "^", Event{ .key = .{
        .value = .{ .codepoint = .init("^") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "&", Event{ .key = .{
        .value = .{ .codepoint = .init("&") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "*", Event{ .key = .{
        .value = .{ .codepoint = .init("*") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "(", Event{ .key = .{
        .value = .{ .codepoint = .init("(") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ")", Event{ .key = .{
        .value = .{ .codepoint = .init(")") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ";", Event{ .key = .{
        .value = .{ .codepoint = .init(";") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ":", Event{ .key = .{
        .value = .{ .codepoint = .init(";") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "'", Event{ .key = .{
        .value = .{ .codepoint = .init("'") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "\"", Event{ .key = .{
        .value = .{ .codepoint = .init("\"") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "/", Event{ .key = .{
        .value = .{ .codepoint = .init("/") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "?", Event{ .key = .{
        .value = .{ .codepoint = .init("?") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "\\", Event{ .key = .{
        .value = .{ .codepoint = .init("\\") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "|", Event{ .key = .{
        .value = .{ .codepoint = .init("|") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "`", Event{ .key = .{
        .value = .{ .codepoint = .init("`") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "~", Event{ .key = .{
        .value = .{ .codepoint = .init("~") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "[", Event{ .key = .{
        .value = .{ .codepoint = .init("[") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "]", Event{ .key = .{
        .value = .{ .codepoint = .init("]") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "{", Event{ .key = .{
        .value = .{ .codepoint = .init("{") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "}", Event{ .key = .{
        .value = .{ .codepoint = .init("}") },
        .modifiers = .{ .alt = true },
    } } },
    .{ "<", Event{ .key = .{
        .value = .{ .codepoint = .init("<") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ">", Event{ .key = .{
        .value = .{ .codepoint = .init(">") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ",", Event{ .key = .{
        .value = .{ .codepoint = .init(",") },
        .modifiers = .{ .alt = true },
    } } },
    .{ ".", Event{ .key = .{
        .value = .{ .codepoint = .init(".") },
        .modifiers = .{ .alt = true },
    } } },
});

/// Terminal input CSI sequences.
const csi_sequences: std.StaticStringMap(Event) = .initComptime(.{
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
    .{ "3;5~", Event{ .key = .{
        .value = .{ .control = .delete },
        .modifiers = .{ .ctrl = true },
    } } },
    .{ "46;5u", Event{ .key = .{
        .value = .{ .codepoint = .init(".") },
        .modifiers = .{ .ctrl = true },
    } } },
    .{ "62;5u", Event{ .key = .{
        .value = .{ .codepoint = .init(".") },
        .modifiers = .{ .ctrl = true, .shift = true },
    } } },
    .{ "96;5u", Event{ .key = .{
        .value = .{ .codepoint = .init("`") },
        .modifiers = .{ .ctrl = true },
    } } },
    .{ "98;6u", Event{ .key = .{
        .value = .{ .codepoint = .init("B") },
        .modifiers = .{ .ctrl = true, .shift = true },
    } } },
    .{ "121;6u", Event{ .key = .{
        .value = .{ .codepoint = .init("Y") },
        .modifiers = .{ .ctrl = true, .shift = true },
    } } },
});
