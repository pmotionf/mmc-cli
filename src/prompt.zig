//! This module contains the functionality for an interactive user prompt.
const builtin = @import("builtin");
const std = @import("std");

const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
const command = @import("command.zig");

/// Hide prompt and ignore user input.
pub var disable: std.atomic.Value(bool) = .init(false);

/// Gracefully exit running prompt handler thread.
pub var close: std.atomic.Value(bool) = .init(false);

const max_input_size = std.fs.max_path_bytes + 512;

var history_buf: [1024][max_input_size]u8 = undefined;
var history: CircularBuffer([]u8, 1024) = .{};
/// Currently displayed history item offset from tail.
var history_offset: ?std.math.IntFittingRange(0, history_buf.len) = null;

var input_buffer: [max_input_size]u8 = undefined;
var input: []u8 = &.{};
var selection: []u8 = &.{};

/// Cursor column index in interactive prompt.
var cursor: u16 = 0;

/// Prompt handler thread callback. Input must be set to non-canonical mode
/// prior to spawning this thread. Only one prompt handler thread may be
/// running at a time.
pub fn handler() void {
    input = &.{};
    selection = &.{};
    history.clearRetainingCapacity();
    history_offset = null;
    cursor = 0;

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var sequence_buffer: [4]u8 = undefined;
    var sequence: []u8 = &.{};

    var timer = std.time.Timer.start() catch unreachable;

    var prev_disable: bool = true;
    main: while (!close.load(.monotonic)) {
        if (disable.load(.monotonic)) {
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
                history_offset = null;
            },
            // Backspace
            0x08, 0x7F => {
                if (cursor < input.len) history_offset = null;
                if (cursor > 0) {
                    const after = input[cursor..];
                    @memmove(
                        input_buffer[cursor - 1 ..][0..after.len],
                        after,
                    );
                    input = input[0 .. input.len - 1];
                    cursor -= 1;
                }
                sequence = &.{};
                if (input.len == 0) history_offset = null;
            },
            // Ctrl-A
            0x01 => {},
            // Ctrl-D
            0x04 => {
                sequence = &.{};
                input = &.{};
                history_offset = null;
            },
            '\n' => {
                sequence = &.{};
                if (history_offset) |offset| {
                    const hist_item = history.buffer[
                        ((history.head) + offset - 1) % history.buffer.len
                    ];

                    input = input_buffer[0..hist_item.len];
                    @memcpy(input, hist_item);
                }
                if (input.len > 0) {
                    disable.store(true, .monotonic);
                    prev_disable = true;
                    stdout.print(
                        "\x1B[{d}G\n",
                        .{input.len},
                    ) catch continue :main;
                    command.enqueue(input) catch continue :main;
                    const buf_slice =
                        history_buf[history.getWriteIndex()][0..input.len];
                    @memcpy(buf_slice, input);
                    history.writeItemOverwrite(buf_slice);
                    history_offset = null;
                    input = &.{};
                    cursor = 0;
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
                if (history_offset) |offset| {
                    const hist_item = history.buffer[
                        ((history.head) + offset - 1) % history.buffer.len
                    ];

                    input = input_buffer[0..hist_item.len];
                    @memcpy(input, hist_item);
                    cursor = @intCast(input.len);
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
                        var remaining = if (history_offset) |offset|
                            if (offset > 0) offset - 1 else offset
                        else
                            history.count;
                        while (remaining > 0) {
                            const old = history.buffer[
                                (history.head + remaining - 1) %
                                    history.buffer.len
                            ];

                            if (std.mem.eql(u8, input, old[0..input.len])) {
                                history_offset = remaining;
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
                        if (cursor >= input.len) {
                            if (history_offset) |offset| {
                                const hist_item = history.buffer[
                                    ((history.head) + offset - 1) %
                                        history.buffer.len
                                ];

                                input = input_buffer[0..hist_item.len];
                                @memcpy(input, hist_item);
                                history_offset = null;
                            }
                            cursor = @intCast(input.len);
                        } else {
                            cursor += 1;
                        }
                    }
                    // Down Arrow
                    else if (std.mem.eql(u8, "\x1B[B", sequence) or
                        std.mem.eql(u8, "\x00\x50", sequence) or
                        std.mem.eql(u8, "\xE0\x50", sequence))
                    {
                        sequence = &.{};
                        if (history_offset) |offset| {
                            var remaining: usize =
                                if (offset > 0) offset + 1 else offset;
                            while (remaining <= history.count) {
                                const old = history.buffer[
                                    (history.head + remaining - 1) %
                                        history.buffer.len
                                ];

                                if (std.mem.eql(
                                    u8,
                                    input,
                                    old[0..input.len],
                                )) {
                                    history_offset = @intCast(remaining);
                                    break;
                                }
                                remaining += 1;
                            } else {
                                history_offset = null;
                            }
                        }
                    }
                    // Left Arrow
                    else if (std.mem.eql(u8, "\x1B[D", sequence) or
                        std.mem.eql(u8, "\x00\x4B", sequence) or
                        std.mem.eql(u8, "\xE0\x4B", sequence))
                    {
                        sequence = &.{};
                        if (cursor > 0) {
                            cursor -= 1;
                        }
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
                    if (cursor > input.len) cursor = @intCast(input.len);
                    const after = input[cursor..];
                    @memmove(input_buffer[cursor + 1 ..][0..after.len], after);
                    input_buffer[cursor] = b;
                    input = input_buffer[0 .. input.len + 1];
                    cursor += 1;
                    if (history_offset) |offset| {
                        const hist_item = history.buffer[
                            ((history.head) + offset - 1) % history.buffer.len
                        ];
                        // Cancel history selection if input length exceeds
                        // history item length.
                        if (input.len > hist_item.len) {
                            history_offset = null;
                        }
                        // Cancel history selection if non-matching character
                        // is inputted.
                        if (hist_item[input.len - 1] != b) {
                            history_offset = null;
                        }
                    }
                }
            },
        }

        stdout.writeAll("\x1B[2K\r") catch continue :main;
        var last_non_space: ?usize = null;
        for (input, 0..) |c, i| {
            if (c == ' ') {
                if (last_non_space) |start| {
                    const fragment = input[start..i];
                    for (command.registry.values()) |com| {
                        if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                            stdout.print(
                                "\x1B[0;32m{s}\x1b[0m",
                                .{fragment},
                            ) catch continue :main;
                            break;
                        }
                    } else {
                        stdout.writeAll(fragment) catch continue :main;
                    }
                }
                last_non_space = null;
                stdout.writeByte(' ') catch continue :main;
            } else if (last_non_space == null) {
                last_non_space = i;
            }
        } else if (last_non_space) |start| {
            const fragment = input[start..];
            for (command.registry.values()) |com| {
                if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                    stdout.print(
                        "\x1B[0;32m{s}\x1b[0m",
                        .{fragment},
                    ) catch continue :main;
                    break;
                }
            } else {
                stdout.writeAll(fragment) catch continue :main;
            }
        }
        if (history_offset) |offset| {
            const hist_item = history.buffer[
                ((history.head) + offset - 1) % history.buffer.len
            ];
            if (hist_item.len > input.len) {
                stdout.print(
                    "\x1B[0;30;47m{s}\x1B[0m",
                    .{hist_item[input.len..]},
                ) catch continue :main;
            }
        }
        // Print cursor
        if (cursor > input.len) cursor = @intCast(input.len);
        stdout.print("\x1B[{d}G", .{cursor + 1}) catch continue :main;
    }
}
