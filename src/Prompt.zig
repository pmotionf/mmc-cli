//! This module contains the functionality for an interactive user prompt.
const Prompt = @This();

const builtin = @import("builtin");
const std = @import("std");

const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
const command = @import("command.zig");

const max_input_size = std.fs.max_path_bytes + 512;
const max_history = 1024;

/// Flag to hide prompt and ignore user input.
disable: std.atomic.Value(bool) = .init(false),
/// Flag to gracefully exit running prompt handler thread.
close: std.atomic.Value(bool) = .init(false),

history_buf: [max_history][max_input_size]u8 = undefined,
history: CircularBuffer([]u8, max_history) = .{},
/// Currently displayed history item offset from tail.
history_offset: ?std.math.IntFittingRange(0, max_history) = null,

input_buffer: [max_input_size]u8 = undefined,
input: []u8 = &.{},

/// Cursor column index in interactive prompt.
cursor: u16 = 0,

fn getHistoryItem(self: *Prompt) ?[]const u8 {
    if (self.history_offset) |offset| {
        return self.history.buffer[
            ((self.history.head) + offset - 1) % self.history.buffer.len
        ];
    } else return null;
}

/// Insert byte at cursor location. Must guarantee that cursor location is
/// between 0 and the current input length, inclusive.
fn insert(self: *Prompt, b: u8) void {
    std.debug.assert(self.cursor <= self.input.len);
    std.debug.assert(self.input.len < self.input_buffer.len);

    // Cancel history selection if insert is in middle of input.
    if (self.cursor < self.input.len) {
        self.history_offset = null;
    }
    const after = self.input[self.cursor..];
    @memmove(self.input_buffer[self.cursor + 1 ..][0..after.len], after);
    self.input_buffer[self.cursor] = b;
    self.input = self.input_buffer[0 .. self.input.len + 1];
    self.cursor += 1;
    if (self.getHistoryItem()) |hist_item| {
        // Cancel selection if input length exceeds history item length.
        if (self.input.len > hist_item.len) {
            self.history_offset = null;
        }
        // Cancel selection if insert does not match.
        if (hist_item[self.input.len - 1] != b) {
            self.history_offset = null;
        }
    }
}

/// Delete one grapheme cursor before cursor.
fn backspace(self: *Prompt) void {
    std.debug.assert(self.cursor <= self.input.len);

    // Cancel history selection if delete is in middle of input.
    if (self.cursor < self.input.len) {
        self.history_offset = null;
    }
    const after = self.input[self.cursor..];

    self.moveCursorLeft();
    @memmove(self.input[self.cursor..][0..after.len], after);

    self.input = self.input[0 .. self.cursor + after.len];
    if (self.input.len == 0) self.history_offset = null;
}

/// Clear input.
fn clear(self: *Prompt) void {
    self.history_offset = null;
    self.input = &.{};
    self.cursor = 0;
}

fn moveCursorLeft(self: *Prompt) void {
    get_to_codepoint_start: while (true) {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        _ = std.unicode.utf8ByteSequenceLength(
            self.input[self.cursor],
        ) catch |e| switch (e) {
            error.Utf8InvalidStartByte => {
                continue :get_to_codepoint_start;
            },
        };
        break :get_to_codepoint_start;
    }
}

fn moveCursorRight(self: *Prompt) void {
    get_to_next_codepoint: while (true) {
        if (self.cursor >= self.input.len) {
            self.cursor = @intCast(self.input.len);
            return;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(
            self.input[self.cursor],
        ) catch |e| switch (e) {
            error.Utf8InvalidStartByte => {
                self.cursor += 1;
                continue :get_to_next_codepoint;
            },
        };
        self.cursor += seq_len;
        break :get_to_next_codepoint;
    }
}

/// Prompt handler thread callback. Input must be set to non-canonical mode
/// prior to spawning this thread. Only one prompt handler thread may be
/// running at a time.
pub fn handler(ctx: *Prompt) void {
    ctx.history.clearRetainingCapacity();
    ctx.clear();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var sequence_buffer: [4]u8 = undefined;
    var sequence: []u8 = &.{};

    var timer = std.time.Timer.start() catch unreachable;

    var prev_disable: bool = true;
    main: while (!ctx.close.load(.monotonic)) {
        if (ctx.disable.load(.monotonic)) {
            prev_disable = true;
            continue :main;
        }

        // Print prompt once on enable.
        if (prev_disable) {
            std.time.sleep(std.time.ns_per_ms * 10);
            stdout.print(
                "Please enter a command (HELP for info):\n",
                .{},
            ) catch continue :main;
        }
        prev_disable = false;

        const b_raw: ?u8 = switch (comptime builtin.os.tag) {
            .linux => b: {
                var fds: [1]std.posix.pollfd =
                    .{.{
                        .fd = std.io.getStdIn().handle,
                        .events = std.posix.POLL.IN,
                        .revents = undefined,
                    }};
                if (std.posix.poll(&fds, 0) catch continue :main > 0) {
                    break :b stdin.readByte() catch continue :main;
                } else {
                    break :b null;
                }
            },
            .windows => b: {
                const threading = @import("win32").system.threading;
                const stdin_handle = std.io.getStdIn().handle;
                if (threading.WaitForSingleObject(
                    stdin_handle,
                    0,
                ) == std.os.windows.WAIT_OBJECT_0) {
                    const console = @import("win32").system.console;
                    var buf: [1]u8 = undefined;
                    var chars_read: u32 = 0;
                    if (console.ReadConsoleA(
                        stdin_handle,
                        &buf,
                        1,
                        &chars_read,
                        null,
                    ) == 0) {
                        continue :main;
                    }
                    if (chars_read == 0) continue :main;
                    break :b buf[0];
                } else {
                    break :b null;
                }
            },
            else => @compileError("unsupported OS"),
        };

        // Start control sequence
        if (b_raw) |br| {
            if (br == 0x9B or br == 0x1B or br == 0x00 or br == 0xE0) {
                sequence_buffer[0] = br;
                sequence = sequence_buffer[0..1];
                timer.reset();
                continue :main;
            }
        }

        const b: u8 = b_raw orelse b: {
            if (sequence.len > 0 and
                timer.read() > std.time.ns_per_ms * 10)
            {
                defer sequence = &.{};
                if (std.mem.eql(u8, "\x1B", sequence)) {
                    break :b '\x1B';
                }
            }
            continue :main;
        };

        parse: switch (b) {
            // Escape
            0x1B => {
                ctx.history_offset = null;
            },
            // Backspace
            0x08, 0x7F => {
                ctx.backspace();
                sequence = &.{};
            },
            // Ctrl-A
            0x01 => {},
            // Ctrl-D
            0x04 => {
                sequence = &.{};
                ctx.clear();
            },
            '\n' => {
                sequence = &.{};
                if (ctx.history_offset) |offset| {
                    const hist_item = ctx.history.buffer[
                        ((ctx.history.head) + offset - 1) %
                            ctx.history.buffer.len
                    ];

                    ctx.input = ctx.input_buffer[0..hist_item.len];
                    @memcpy(ctx.input, hist_item);
                }
                if (ctx.input.len > 0) {
                    ctx.disable.store(true, .monotonic);
                    prev_disable = true;
                    stdout.print(
                        "\x1B[{d}G\n",
                        .{ctx.input.len},
                    ) catch continue :main;
                    command.enqueue(ctx.input) catch continue :main;
                    const buf_slice = ctx.history_buf[
                        ctx.history.getWriteIndex()
                    ][0..ctx.input.len];
                    @memcpy(buf_slice, ctx.input);
                    ctx.history.writeItemOverwrite(buf_slice);
                    ctx.clear();
                    continue :main;
                }
            },
            '\r' => {
                sequence = &.{};
                if (comptime builtin.target.os.tag == .windows) {
                    continue :parse '\n';
                }
            },
            '\t' => {
                if (ctx.history_offset) |offset| {
                    const hist_item = ctx.history.buffer[
                        ((ctx.history.head) + offset - 1) %
                            ctx.history.buffer.len
                    ];

                    ctx.input = ctx.input_buffer[0..hist_item.len];
                    @memcpy(ctx.input, hist_item);
                    ctx.cursor = @intCast(ctx.input.len);
                }
            },
            else => {
                if (sequence.len > 0) {
                    sequence_buffer[sequence.len] = b;
                    sequence = sequence_buffer[0 .. sequence.len + 1];
                    // Backspace
                    if (std.mem.eql(u8, "\x9B?", sequence) or
                        std.mem.eql(u8, "\x9BH", sequence))
                    {
                        sequence = &.{};
                        continue :parse 0x08;
                    }
                    // Up Arrow
                    else if (std.mem.eql(u8, "\x1B[A", sequence) or
                        std.mem.eql(u8, "\x00\x48", sequence) or
                        std.mem.eql(u8, "\xE0\x48", sequence))
                    {
                        sequence = &.{};
                        var remaining = if (ctx.history_offset) |offset|
                            if (offset > 0) offset - 1 else offset
                        else
                            ctx.history.count;
                        while (remaining > 0) {
                            const old = ctx.history.buffer[
                                (ctx.history.head + remaining - 1) %
                                    ctx.history.buffer.len
                            ];

                            if (std.mem.eql(
                                u8,
                                ctx.input,
                                old[0..ctx.input.len],
                            )) {
                                ctx.history_offset = remaining;
                                break;
                            }
                            remaining -= 1;
                        }
                    }
                    // Right Arrow
                    else if (std.mem.eql(u8, "\x1B[C", sequence) or
                        std.mem.eql(u8, "\x00\x4D", sequence) or
                        std.mem.eql(u8, "\xE0\x4D", sequence))
                    {
                        sequence = &.{};
                        if (ctx.cursor >= ctx.input.len) {
                            if (ctx.history_offset) |offset| {
                                const hist_item = ctx.history.buffer[
                                    ((ctx.history.head) + offset - 1) %
                                        ctx.history.buffer.len
                                ];

                                ctx.input = ctx.input_buffer[0..hist_item.len];
                                @memcpy(ctx.input, hist_item);
                                ctx.history_offset = null;
                            }
                            ctx.cursor = @intCast(ctx.input.len);
                        } else {
                            ctx.moveCursorRight();
                        }
                    }
                    // Down Arrow
                    else if (std.mem.eql(u8, "\x1B[B", sequence) or
                        std.mem.eql(u8, "\x00\x50", sequence) or
                        std.mem.eql(u8, "\xE0\x50", sequence))
                    {
                        sequence = &.{};
                        if (ctx.history_offset) |offset| {
                            var remaining: usize =
                                if (offset > 0) offset + 1 else offset;
                            while (remaining <= ctx.history.count) {
                                const old = ctx.history.buffer[
                                    (ctx.history.head + remaining - 1) %
                                        ctx.history.buffer.len
                                ];

                                if (std.mem.eql(
                                    u8,
                                    ctx.input,
                                    old[0..ctx.input.len],
                                )) {
                                    ctx.history_offset = @intCast(remaining);
                                    break;
                                }
                                remaining += 1;
                            } else {
                                ctx.history_offset = null;
                            }
                        }
                    }
                    // Left Arrow
                    else if (std.mem.eql(u8, "\x1B[D", sequence) or
                        std.mem.eql(u8, "\x00\x4B", sequence) or
                        std.mem.eql(u8, "\xE0\x4B", sequence))
                    {
                        sequence = &.{};
                        ctx.moveCursorLeft();
                    }
                    // Continue filling in sequence
                    else {
                        // Unknown sequence
                        if (sequence.len == sequence_buffer.len) {
                            sequence = &.{};
                            continue :parse b;
                        }
                        timer.reset();
                        continue :main;
                    }
                } else {
                    ctx.insert(b);
                }
            },
        }

        // Clear input line to prepare for writing
        stdout.writeAll("\x1B[2K\r") catch continue :main;

        // Parse and print syntax highlighted input
        var last_non_space: ?usize = null;
        for (ctx.input, 0..) |c, i| {
            if (c == ' ') {
                if (last_non_space) |start| {
                    const fragment = ctx.input[start..i];
                    for (command.registry.values()) |com| {
                        if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                            stdout.print(
                                "\x1B[0;32m{s}\x1b[0m",
                                .{fragment},
                            ) catch continue :main;
                            break;
                        }
                    } else {
                        var it = command.variables.iterator();
                        while (it.next()) |var_entry| {
                            if (std.mem.eql(
                                u8,
                                var_entry.key_ptr.*,
                                fragment,
                            )) {
                                stdout.print(
                                    "\x1B[0;35m{s}\x1b[0m",
                                    .{fragment},
                                ) catch continue :main;
                                break;
                            }
                        } else {
                            stdout.writeAll(fragment) catch continue :main;
                        }
                    }
                }
                last_non_space = null;
                stdout.writeByte(' ') catch continue :main;
            } else if (last_non_space == null) {
                last_non_space = i;
            }
        } else if (last_non_space) |start| {
            const fragment = ctx.input[start..];
            for (command.registry.values()) |com| {
                if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                    stdout.print(
                        "\x1B[0;32m{s}\x1b[0m",
                        .{fragment},
                    ) catch continue :main;
                    break;
                }
            } else {
                var it = command.variables.iterator();
                while (it.next()) |var_entry| {
                    if (std.mem.eql(u8, var_entry.key_ptr.*, fragment)) {
                        stdout.print(
                            "\x1B[0;35m{s}\x1b[0m",
                            .{fragment},
                        ) catch continue :main;
                        break;
                    }
                } else {
                    stdout.writeAll(fragment) catch continue :main;
                }
            }
        }

        // Print history suggestion if exists
        if (ctx.history_offset) |offset| {
            const hist_item = ctx.history.buffer[
                ((ctx.history.head) + offset - 1) % ctx.history.buffer.len
            ];
            if (hist_item.len > ctx.input.len) {
                stdout.print(
                    "\x1B[0;30;47m{s}\x1B[0m",
                    .{hist_item[ctx.input.len..]},
                ) catch continue :main;
            }
        }

        // Print cursor
        if (ctx.cursor > ctx.input.len) ctx.cursor = @intCast(ctx.input.len);
        stdout.print("\x1B[{d}G", .{ctx.cursor + 1}) catch continue :main;
    }
}
