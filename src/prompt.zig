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

/// Prompt handler thread callback. Input must be set to non-canonical mode
/// prior to spawning this thread. Only one prompt handler thread may be
/// running at a time.
pub fn handler() void {
    var input_buffer: [max_input_size]u8 = undefined;
    var input: []u8 = &.{};

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
            .windows => {
                // TODO
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
                if (input.len > 0) {
                    input = input[0 .. input.len - 1];
                } else {
                    history_offset = null;
                }
                sequence = &.{};
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
                    command.enqueue(input) catch continue :main;
                    const buf_slice =
                        history_buf[history.getWriteIndex()][0..input.len];
                    @memcpy(buf_slice, input);
                    history.writeItemOverwrite(buf_slice);
                    history_offset = null;
                    input = &.{};
                    stdout.writeByte('\n') catch continue :main;
                    continue :main;
                }
            },
            '\r' => {
                sequence = &.{};
            },
            '\t' => {
                if (history_offset) |offset| {
                    const hist_item = history.buffer[
                        ((history.head) + offset - 1) % history.buffer.len
                    ];

                    input = input_buffer[0..hist_item.len];
                    @memcpy(input, hist_item);
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
                        if (history_offset) |offset| {
                            const hist_item = history.buffer[
                                ((history.head) + offset - 1) %
                                    history.buffer.len
                            ];

                            input = input_buffer[0..hist_item.len];
                            @memcpy(input, hist_item);
                            history_offset = null;
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
                    input_buffer[input.len] = b;
                    input = input_buffer[0 .. input.len + 1];
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

        stdout.print("\x1B[2K\r{s}", .{input}) catch continue :main;
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
    }
}
