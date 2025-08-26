//! This module contains the functionality for an interactive user prompt.
const Prompt = @This();

const builtin = @import("builtin");
const std = @import("std");

const command = @import("command.zig");
const io = @import("io.zig");

const Complete = @import("Prompt/Complete.zig");
const History = @import("Prompt/History.zig");

pub const max_input_size = std.fs.max_path_bytes + 512;

/// Flag to hide prompt and ignore user input.
disable: std.atomic.Value(bool) = .init(false),
/// Flag to gracefully exit running prompt handler thread.
close: std.atomic.Value(bool) = .init(false),

history: History = .{},

complete: Complete = .{ .kind = .command },
/// Start index of partial that has generated the currently available
/// completion suggestion.
complete_partial_start: ?usize = null,
/// Currently selected completion, if completion has been selected.
complete_selection: ?usize = null,

input_buffer: [max_input_size]u8 = undefined,
input: []u8 = &.{},

cursor: Cursor = .{},

/// Prompt handler thread callback. Input must be set to non-canonical mode
/// prior to spawning this thread. Only one prompt handler thread may be
/// running at a time.
pub fn handler(ctx: *Prompt) void {
    ctx.history.clear();
    ctx.clear();

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);

    var prev_disable: bool = true;
    main: while (!ctx.close.load(.monotonic)) {
        if (ctx.disable.load(.monotonic)) {
            prev_disable = true;
            continue :main;
        }
        defer stdout.interface.flush() catch {};

        // Print prompt once on enable.
        if (prev_disable) {
            std.Thread.sleep(std.time.ns_per_ms * 10);
            stdout.interface.writeAll(
                "Please enter a command (HELP for info):\n",
            ) catch continue :main;
            stdout.interface.flush() catch continue :main;
        }
        prev_disable = false;

        if (io.event.poll() catch continue :main == 0) {
            continue :main;
        }

        // By default, we should de-select completion if there is a suggestion
        // that is selected. Only if the input is a Tab/Shift-Tab should we
        // keep the completion selection.
        var keep_complete_selection: bool = false;

        const event = io.event.read(.{}) catch continue :main;
        parse: switch (event) {
            .key => |key_event| {
                switch (key_event.value) {
                    .control => |control_key| {
                        switch (control_key) {
                            .escape => {
                                ctx.history.selection = null;
                            },
                            .backspace => {
                                // Whether first deleted is whitespace.
                                const is_ws: bool = if (ctx.cursor.raw > 0 and
                                    std.ascii.isWhitespace(
                                        ctx.input[ctx.cursor.raw - 1],
                                    ))
                                    true
                                else
                                    false;
                                ctx.backspace();
                                if (key_event.modifiers.ctrl) {
                                    if (is_ws) {
                                        while (ctx.cursor.raw > 0 and
                                            std.ascii.isWhitespace(
                                                ctx.input[ctx.cursor.raw - 1],
                                            ))
                                        {
                                            ctx.backspace();
                                        }
                                    } else {
                                        while (ctx.cursor.raw > 0 and
                                            !std.mem.containsAtLeastScalar(
                                                u8,
                                                separators,
                                                1,
                                                ctx.input[ctx.cursor.raw - 1],
                                            ))
                                        {
                                            ctx.backspace();
                                        }
                                    }
                                }
                            },
                            .delete => {
                                // Whether first deleted is whitespace.
                                var is_ws: bool = false;
                                if (!ctx.cursor.isAtEnd()) {
                                    is_ws = std.ascii.isWhitespace(
                                        ctx.input[ctx.cursor.raw],
                                    );
                                    ctx.cursor.moveRight();
                                    ctx.backspace();
                                }
                                if (key_event.modifiers.ctrl) {
                                    if (is_ws) {
                                        while (!ctx.cursor.isAtEnd() and
                                            std.ascii.isWhitespace(
                                                ctx.input[ctx.cursor.raw],
                                            ))
                                        {
                                            ctx.cursor.moveRight();
                                            ctx.backspace();
                                        }
                                    } else {
                                        while (!ctx.cursor.isAtEnd() and
                                            !std.mem.containsAtLeastScalar(
                                                u8,
                                                separators,
                                                1,
                                                ctx.input[ctx.cursor.raw],
                                            ))
                                        {
                                            ctx.cursor.moveRight();
                                            ctx.backspace();
                                        }
                                    }
                                }
                            },
                            .enter => {
                                if (ctx.history.selection) |*selection| {
                                    const hist_item = selection.slice();
                                    ctx.input =
                                        ctx.input_buffer[0..hist_item.len];
                                    @memcpy(ctx.input, hist_item);
                                }
                                if (ctx.input.len > 0) {
                                    ctx.disable.store(true, .monotonic);
                                    prev_disable = true;

                                    // Print newline at end of prompt before
                                    // command start.
                                    ctx.cursor.moveEnd();
                                    io.cursor.moveColumn(
                                        &stdout.interface,
                                        ctx.cursor.visible + 1,
                                    ) catch continue :main;
                                    stdout.interface.writeByte('\n') catch
                                        continue :main;
                                    stdout.interface.flush() catch
                                        continue :main;

                                    command.enqueue(ctx.input) catch
                                        continue :main;
                                    ctx.history.append(ctx.input);
                                    ctx.history.selection = null;
                                    ctx.clear();
                                    continue :main;
                                }
                            },
                            .tab => {
                                if (ctx.history.selection) |*selection| {
                                    const hist_item = selection.slice();
                                    ctx.input =
                                        ctx.input_buffer[0..hist_item.len];
                                    @memcpy(ctx.input, hist_item);
                                    ctx.cursor.moveEnd();
                                    ctx.history.selection = null;
                                } else if (ctx.complete_partial_start) |cvs| {
                                    keep_complete_selection = true;
                                    const prefix = ctx.complete.prefix;
                                    const sg = ctx.complete.suggestions;

                                    // Scroll suggestions if completed.
                                    if (ctx.complete_selection) |idx| {
                                        if (key_event.modifiers.shift) {
                                            if (idx > 0) {
                                                ctx.complete_selection =
                                                    idx - 1;
                                                while (ctx.cursor.raw > cvs) {
                                                    ctx.backspace();
                                                }
                                                ctx.insertString(sg[idx - 1]);
                                            }
                                        } else if (idx < sg.len - 1) {
                                            ctx.complete_selection = idx + 1;
                                            while (ctx.cursor.raw > cvs) {
                                                ctx.backspace();
                                            }
                                            ctx.insertString(sg[idx + 1]);
                                        }
                                    }
                                    // Select suggestion if not completed.
                                    else if (prefix.len > 0) {
                                        const partial =
                                            ctx.input[cvs..ctx.cursor.raw];
                                        // Prefix is available to complete.
                                        if (prefix.len > partial.len) {
                                            while (ctx.cursor.raw > cvs) {
                                                ctx.backspace();
                                            }
                                            ctx.insertString(prefix);
                                        }
                                        // Prefix already completed, manually
                                        // trigger cycling through remaining
                                        // suggestions.
                                        else if (sg.len > 1) {
                                            while (ctx.cursor.raw > cvs) {
                                                ctx.backspace();
                                            }
                                            ctx.insertString(sg[0]);
                                            ctx.complete_selection = 0;
                                        }
                                    }
                                }
                            },
                            .arrow_up => {
                                if (ctx.history.selection) |*selection| {
                                    selection.previous(ctx.input);
                                } else {
                                    ctx.history.select(ctx.input);
                                }
                            },
                            .arrow_right => ar: {
                                // Complete suggestion if visible.
                                if (ctx.complete_partial_start) |cvs| {
                                    const prefix = ctx.complete.prefix;
                                    const partial =
                                        ctx.input[cvs..ctx.cursor.raw];
                                    // Prefix is available to complete.
                                    if (prefix.len > partial.len) {
                                        while (ctx.cursor.raw > cvs) {
                                            ctx.backspace();
                                        }
                                        ctx.insertString(prefix);

                                        keep_complete_selection = true;
                                        break :ar;
                                    }
                                }

                                if (ctx.cursor.raw >= ctx.input.len) {
                                    if (ctx.history.selection) |*selection| {
                                        const hist_item = selection.slice();

                                        ctx.input =
                                            ctx.input_buffer[0..hist_item.len];
                                        @memcpy(ctx.input, hist_item);
                                        ctx.history.selection = null;
                                    }
                                    ctx.cursor.moveEnd();
                                } else {
                                    ctx.cursor.moveRight();
                                    if (key_event.modifiers.ctrl) {
                                        while (!ctx.cursor.isAtEnd() and
                                            !std.mem.containsAtLeastScalar(
                                                u8,
                                                separators,
                                                1,
                                                ctx.input[ctx.cursor.raw],
                                            ))
                                        {
                                            ctx.cursor.moveRight();
                                        }
                                    }
                                }
                            },
                            .arrow_down => {
                                if (ctx.history.selection) |*selection| {
                                    selection.next(ctx.input);
                                }
                            },
                            .arrow_left => {
                                ctx.cursor.moveLeft();
                                if (key_event.modifiers.ctrl) {
                                    while (ctx.cursor.raw > 0 and
                                        !std.mem.containsAtLeastScalar(
                                            u8,
                                            separators,
                                            1,
                                            ctx.input[ctx.cursor.raw],
                                        ))
                                    {
                                        ctx.cursor.moveLeft();
                                    }
                                }
                            },
                            .home => {
                                while (ctx.cursor.raw > 0) {
                                    ctx.cursor.moveLeft();
                                }
                            },
                            .end => {
                                while (ctx.cursor.raw < ctx.input.len) {
                                    ctx.cursor.moveRight();
                                }
                            },
                            else => {},
                        }
                    },
                    .codepoint => |cp| {
                        const cp_seq = cp.sequence();
                        if (key_event.modifiers.ctrl and cp_seq.len == 1) {
                            switch (cp_seq[0]) {
                                'd' => {
                                    ctx.clear();
                                    break :parse;
                                },
                                'v' => {
                                    switch (comptime builtin.os.tag) {
                                        .windows => {
                                            var buf: [max_input_size]u8 =
                                                undefined;
                                            const paste = io.clipboard.get(
                                                &buf,
                                            ) catch {};
                                            ctx.insertString(paste);
                                            break :parse;
                                        },
                                        else => {},
                                    }
                                },
                                else => {},
                            }
                        }
                        ctx.insertCodepoint(cp_seq);
                    },
                }
            },
            .mouse => {
                // TODO
            },
        }

        if (!keep_complete_selection) {
            ctx.complete_selection = null;
            ctx.complete.setPartial("");
        }

        // Generate completion suggestion.
        const start_completion: ?usize = completion: {
            if (ctx.cursor.raw == 0) break :completion null;
            if (ctx.cursor.raw < ctx.input.len and
                ctx.input[ctx.cursor.raw] != ' ') break :completion null;
            if (ctx.input[ctx.cursor.raw - 1] == ' ') break :completion null;
            if (ctx.history.selection != null) break :completion null;
            if (ctx.complete_selection != null) {
                if (ctx.complete_partial_start) |cvs| {
                    break :completion cvs;
                }
            }

            const start_ind = if (std.mem.lastIndexOfScalar(
                u8,
                ctx.input[0..ctx.cursor.raw],
                ' ',
            )) |si| si + 1 else 0;

            if (start_ind > 0) {
                if (std.mem.allEqual(u8, ctx.input[0..start_ind], ' ')) {
                    ctx.complete.kind = .command;
                } else {
                    ctx.complete.kind = .variable;
                }
            } else {
                ctx.complete.kind = .command;
            }

            const partial = ctx.input[start_ind..ctx.cursor.raw];
            ctx.complete.setPartial(partial);

            break :completion start_ind;
        };
        ctx.complete_partial_start = start_completion;

        // Clear input line to prepare for writing
        stdout.interface.writeAll("\x1B[2K\r") catch continue :main;

        // Parse and print syntax highlighted input
        var last_frag_start: ?usize = null; // Last start byte != ' '.
        for (ctx.input, 0..) |c, i| {
            if (c == ' ') {
                if (last_frag_start) |start| {
                    // Underline fragment if it has just been completed.
                    if (ctx.complete_partial_start) |cvs| {
                        if (cvs == start and ctx.complete_selection != null) {
                            io.style.set(
                                &stdout.interface,
                                .{ .underline = true },
                            ) catch continue :main;
                        }
                    }
                    const fragment = ctx.input[start..i];
                    for (command.registry.values()) |com| {
                        if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                            io.style.set(&stdout.interface, .{
                                .fg = .{ .named = .green },
                            }) catch continue :main;
                            defer io.style.reset(&stdout.interface) catch {};
                            stdout.interface.writeAll(fragment) catch
                                continue :main;
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
                                io.style.set(&stdout.interface, .{
                                    .fg = .{ .named = .magenta },
                                }) catch continue :main;
                                defer io.style.reset(
                                    &stdout.interface,
                                ) catch {};
                                stdout.interface.writeAll(fragment) catch
                                    continue :main;
                                break;
                            }
                        } else {
                            stdout.interface.writeAll(fragment) catch
                                continue :main;
                        }
                    }
                }
                last_frag_start = null;

                // Print completion suggestion before cursor.
                if (start_completion) |start_ind| {
                    if (i == ctx.cursor.raw) {
                        const completed_len = ctx.cursor.raw - start_ind;
                        if (ctx.complete.prefix.len > completed_len) {
                            const suggestion =
                                ctx.complete.prefix[completed_len..];
                            io.style.set(&stdout.interface, .{
                                .fg = .{ .lut = .grayscale(12) },
                            }) catch continue :main;
                            defer io.style.reset(&stdout.interface) catch {};
                            stdout.interface.writeAll(suggestion) catch
                                continue :main;
                        }
                    }
                }

                stdout.interface.writeByte(' ') catch continue :main;
            } else if (last_frag_start == null) {
                last_frag_start = i;
            }
        } else {
            if (last_frag_start) |start| {
                // Underline fragment if it has just been completed.
                if (ctx.complete_partial_start) |cvs| {
                    if (cvs == start and ctx.complete_selection != null) {
                        io.style.set(
                            &stdout.interface,
                            .{ .underline = true },
                        ) catch continue :main;
                    }
                }
                const fragment = ctx.input[start..];
                for (command.registry.values()) |com| {
                    if (std.ascii.eqlIgnoreCase(com.name, fragment)) {
                        io.style.set(&stdout.interface, .{
                            .fg = .{ .named = .green },
                        }) catch continue :main;
                        defer io.style.reset(&stdout.interface) catch {};
                        stdout.interface.writeAll(fragment) catch
                            continue :main;
                        break;
                    }
                } else {
                    var it = command.variables.iterator();
                    while (it.next()) |var_entry| {
                        if (std.mem.eql(u8, var_entry.key_ptr.*, fragment)) {
                            io.style.set(&stdout.interface, .{
                                .fg = .{ .named = .magenta },
                            }) catch continue :main;
                            defer io.style.reset(&stdout.interface) catch {};
                            stdout.interface.writeAll(fragment) catch
                                continue :main;
                            break;
                        }
                    } else {
                        stdout.interface.writeAll(fragment) catch
                            continue :main;
                    }
                }
            }
            if (ctx.cursor.raw == ctx.input.len) {
                // Print completion suggestion before cursor.
                if (start_completion) |start_ind| {
                    const completed_len = ctx.cursor.raw - start_ind;
                    if (ctx.complete.prefix.len > completed_len) {
                        const suggestion =
                            ctx.complete.prefix[completed_len..];
                        io.style.set(&stdout.interface, .{
                            .fg = .{ .lut = .grayscale(12) },
                        }) catch continue :main;
                        defer io.style.reset(&stdout.interface) catch {};
                        stdout.interface.writeAll(suggestion) catch
                            continue :main;
                    }
                }
            }
        }

        // Print history suggestion if exists
        if (ctx.history.selection) |*selection| {
            const hist_item = selection.slice();
            if (hist_item.len > ctx.input.len) {
                io.style.set(&stdout.interface, .{
                    .fg = .{ .lut = .grayscale(12) },
                    .underline = true,
                }) catch continue :main;
                defer io.style.reset(&stdout.interface) catch {};
                stdout.interface.writeAll(hist_item[ctx.input.len..]) catch
                    continue :main;
            }
        }

        io.cursor.moveColumn(&stdout.interface, ctx.cursor.visible + 1) catch
            continue :main;
    }
}

const separators: []const u8 = " ,._-()[]{}`~+=*!@#$%^&|\\/'\":;<>?\t\n";

const Cursor = struct {
    raw: std.math.IntFittingRange(0, max_input_size) = 0,
    visible: u16 = 0,

    fn isAtEnd(self: *const Cursor) bool {
        const ctx: *const Prompt =
            @alignCast(@fieldParentPtr("cursor", self));
        return self.raw == ctx.input.len;
    }

    fn moveLeft(self: *Cursor) void {
        const ctx: *Prompt = @alignCast(@fieldParentPtr("cursor", self));

        const seq_len = get_to_codepoint_start: while (true) {
            if (self.raw == 0) return;
            self.raw -= 1;
            break :get_to_codepoint_start std.unicode.utf8ByteSequenceLength(
                ctx.input[self.raw],
            ) catch |e| switch (e) {
                error.Utf8InvalidStartByte => {
                    continue :get_to_codepoint_start;
                },
            };
        };
        if (self.visible > 0) {
            self.visible -= utfDisplayWidth(
                ctx.input[self.raw..][0..seq_len],
            );
        }
    }

    fn moveRight(self: *Cursor) void {
        const ctx: *Prompt = @alignCast(@fieldParentPtr("cursor", self));

        var started_from_invalid: bool = false;
        get_to_next_codepoint: while (true) {
            if (self.raw >= ctx.input.len) {
                self.raw = @intCast(ctx.input.len);
                return;
            }
            const seq_len = std.unicode.utf8ByteSequenceLength(
                ctx.input[self.raw],
            ) catch |e| switch (e) {
                error.Utf8InvalidStartByte => {
                    self.raw += 1;
                    started_from_invalid = true;
                    continue :get_to_next_codepoint;
                },
            };
            if (started_from_invalid) break :get_to_next_codepoint;

            self.visible += utfDisplayWidth(
                ctx.input[self.raw..][0..seq_len],
            );
            self.raw += seq_len;
            break :get_to_next_codepoint;
        }
    }

    fn moveEnd(self: *Cursor) void {
        const ctx: *Prompt = @alignCast(@fieldParentPtr("cursor", self));
        self.raw = @intCast(ctx.input.len);
        var it = (std.unicode.Utf8View.init(ctx.input) catch {
            self.visible = @intCast(self.raw);
            return;
        }).iterator();
        self.visible = 0;
        while (it.nextCodepointSlice()) |cp| {
            self.visible += utfDisplayWidth(cp);
        }
    }
};

/// Insert byte at cursor location. Must guarantee that cursor location is
/// between 0 and the current input length, inclusive.
fn insert(self: *Prompt, b: u8) void {
    std.debug.assert(self.cursor.raw <= self.input.len);
    std.debug.assert(self.input.len < self.input_buffer.len);

    // Cancel history selection if insert is in middle of input.
    if (self.cursor.raw < self.input.len) {
        self.history_offset = null;
    }
    const after = self.input[self.cursor.raw..];
    @memmove(self.input_buffer[self.cursor.raw + 1 ..][0..after.len], after);
    self.input_buffer[self.cursor.raw] = b;
    self.input = self.input_buffer[0 .. self.input.len + 1];
    self.cursor.raw += 1;
    self.cursor.visible += 1;
    if (self.getHistoryItem()) |hist_item| check_history: {
        // Cancel selection if input length exceeds history item length.
        if (self.input.len > hist_item.len) {
            self.history_offset = null;
            break :check_history;
        }
        // Cancel selection if insert does not match.
        if (hist_item[self.input.len - 1] != b) {
            self.history_offset = null;
            break :check_history;
        }
    }
}

fn insertCodepoint(self: *Prompt, cp: []const u8) void {
    std.debug.assert(self.cursor.raw <= self.input.len);
    std.debug.assert(self.input.len + cp.len <= self.input_buffer.len);
    std.debug.assert(cp.len <= 4);

    // Cancel history selection if insert is in middle of input.
    if (self.cursor.raw < self.input.len) {
        self.history.selection = null;
    }
    const after = self.input[self.cursor.raw..];
    @memmove(
        self.input_buffer[self.cursor.raw + cp.len ..][0..after.len],
        after,
    );
    @memcpy(self.input_buffer[self.cursor.raw..][0..cp.len], cp);
    self.input = self.input_buffer[0 .. self.input.len + cp.len];
    self.cursor.moveRight();
    if (self.history.selection) |*selection| {
        const hist_item = selection.slice();
        // Cancel selection if input length exceeds history item length.
        if (self.input.len >= hist_item.len) {
            self.history.selection = null;
        }
        // Cancel selection if insert does not match.
        for (cp, 0..) |c, i| {
            if (c != hist_item[self.input.len - cp.len + i]) {
                self.history.selection = null;
                break;
            }
        }
    }
}

/// Insert UTF-8 encoded string.
fn insertString(self: *Prompt, string: []const u8) void {
    std.debug.assert(self.cursor.raw <= self.input.len);
    std.debug.assert(self.input.len + string.len <= self.input_buffer.len);

    // Cancel history selection if insert is in middle of input.
    if (self.cursor.raw < self.input.len) {
        self.history.selection = null;
    }
    const after = self.input[self.cursor.raw..];
    @memmove(
        self.input_buffer[self.cursor.raw + string.len ..][0..after.len],
        after,
    );
    @memcpy(self.input_buffer[self.cursor.raw..][0..string.len], string);
    self.input = self.input_buffer[0 .. self.input.len + string.len];
    const after_raw_pos = self.cursor.raw + string.len;
    while (self.cursor.raw < after_raw_pos) {
        self.cursor.moveRight();
    }

    if (self.history.selection) |*selection| {
        const hist_item = selection.slice();
        // Cancel selection if input length exceeds history item length.
        if (self.input.len > hist_item.len) {
            self.history.selection = null;
        }

        // Cancel selection if insert does not match.
        if (!std.mem.eql(
            u8,
            hist_item[self.input.len - string.len ..][0..string.len],
            string,
        )) {
            self.history.selection = null;
        }
    }
}

/// Delete one grapheme cursor before cursor.
fn backspace(self: *Prompt) void {
    std.debug.assert(self.cursor.raw <= self.input.len);

    // Cancel history selection if delete is in middle of input.
    if (self.cursor.raw < self.input.len) {
        self.history.selection = null;
    }
    const after = self.input[self.cursor.raw..];

    self.cursor.moveLeft();
    @memmove(self.input[self.cursor.raw..][0..after.len], after);

    self.input = self.input[0 .. self.cursor.raw + after.len];
    if (self.input.len == 0) self.history.selection = null;
}

/// Clear input.
fn clear(self: *Prompt) void {
    self.history.selection = null;
    self.input = &.{};
    self.complete_partial_start = null;
    self.complete_selection = null;
    self.cursor = .{
        .raw = 0,
        .visible = 0,
    };
}

const Interval = struct { first: u32, last: u32 };

fn bisearch(ucs: u16, table: []const Interval, max_: usize) bool {
    var min: usize = 0;
    var mid: usize = undefined;
    var max: usize = max_;

    if (ucs < table[0].first or ucs > table[max].last)
        return false;
    while (max >= min) {
        mid = (min + max) / 2;
        if (ucs > table[mid].last) {
            min = mid + 1;
        } else if (ucs < table[mid].first) {
            max = mid - 1;
        } else return true;
    }

    return false;
}

/// Calculates display width of UTF-8 codepoint.
/// Defines the column width of an ISO 10646 character as follows:
///   - The null character (U+0000) has a column width of 0.
///   - Other C0/C1 control characters and DEL will lead to a
///     return value of 0.
///   - Non-spacing and enclosing combining characters (general
///     category code Mn or Me in the Unicode database) have a
///     column width of 0.
///   - SOFT HYPHEN (U+00AD) has a column width of 1.
///   - Other format characters (general category code Cf in the Unicode
///     database) and ZERO WIDTH SPACE (U+200B) have a column width of 0.
///   - Hangul Jamo medial vowels and final consonants (U+1160-U+11FF)
///     have a column width of 0.
///   - Spacing characters in the East Asian Wide (W) or East Asian
///     Full-width (F) category as defined in Unicode Technical
///     Report #11 have a column width of 2.
///   - All remaining characters (including all printable
///     ISO 8859-1 and WGL4 characters, Unicode control characters,
///     etc.) have a column width of 1.
/// This implementation assumes that wide (u16) characters are encoded
/// in ISO 10646.
fn utfDisplayWidth(cp: []const u8) u3 {
    std.debug.assert(cp.len <= 4);
    if (cp.len == 0) return 0;

    var ucs_buf: [2]u16 = undefined;
    const idx = std.unicode.utf8ToUtf16Le(&ucs_buf, cp) catch unreachable;
    // Unicode codepoint is outside Basic Multilingual Plane, default to
    // giving width of 2.
    if (idx == 2) {
        return 2;
    }

    const ucs = ucs_buf[0];

    // sorted list of non-overlapping intervals of non-spacing characters
    // generated by "uniset +cat=Me +cat=Mn +cat=Cf -00AD +1160-11FF +200B c"
    const combining: []const Interval = &.{
        .{ .first = 0x0300, .last = 0x036F },
        .{ .first = 0x0483, .last = 0x0486 },
        .{ .first = 0x0488, .last = 0x0489 },
        .{ .first = 0x0591, .last = 0x05BD },
        .{ .first = 0x05BF, .last = 0x05BF },
        .{ .first = 0x05C1, .last = 0x05C2 },
        .{ .first = 0x05C4, .last = 0x05C5 },
        .{ .first = 0x05C7, .last = 0x05C7 },
        .{ .first = 0x0600, .last = 0x0603 },
        .{ .first = 0x0610, .last = 0x0615 },
        .{ .first = 0x064B, .last = 0x065E },
        .{ .first = 0x0670, .last = 0x0670 },
        .{ .first = 0x06D6, .last = 0x06E4 },
        .{ .first = 0x06E7, .last = 0x06E8 },
        .{ .first = 0x06EA, .last = 0x06ED },
        .{ .first = 0x070F, .last = 0x070F },
        .{ .first = 0x0711, .last = 0x0711 },
        .{ .first = 0x0730, .last = 0x074A },
        .{ .first = 0x07A6, .last = 0x07B0 },
        .{ .first = 0x07EB, .last = 0x07F3 },
        .{ .first = 0x0901, .last = 0x0902 },
        .{ .first = 0x093C, .last = 0x093C },
        .{ .first = 0x0941, .last = 0x0948 },
        .{ .first = 0x094D, .last = 0x094D },
        .{ .first = 0x0951, .last = 0x0954 },
        .{ .first = 0x0962, .last = 0x0963 },
        .{ .first = 0x0981, .last = 0x0981 },
        .{ .first = 0x09BC, .last = 0x09BC },
        .{ .first = 0x09C1, .last = 0x09C4 },
        .{ .first = 0x09CD, .last = 0x09CD },
        .{ .first = 0x09E2, .last = 0x09E3 },
        .{ .first = 0x0A01, .last = 0x0A02 },
        .{ .first = 0x0A3C, .last = 0x0A3C },
        .{ .first = 0x0A41, .last = 0x0A42 },
        .{ .first = 0x0A47, .last = 0x0A48 },
        .{ .first = 0x0A4B, .last = 0x0A4D },
        .{ .first = 0x0A70, .last = 0x0A71 },
        .{ .first = 0x0A81, .last = 0x0A82 },
        .{ .first = 0x0ABC, .last = 0x0ABC },
        .{ .first = 0x0AC1, .last = 0x0AC5 },
        .{ .first = 0x0AC7, .last = 0x0AC8 },
        .{ .first = 0x0ACD, .last = 0x0ACD },
        .{ .first = 0x0AE2, .last = 0x0AE3 },
        .{ .first = 0x0B01, .last = 0x0B01 },
        .{ .first = 0x0B3C, .last = 0x0B3C },
        .{ .first = 0x0B3F, .last = 0x0B3F },
        .{ .first = 0x0B41, .last = 0x0B43 },
        .{ .first = 0x0B4D, .last = 0x0B4D },
        .{ .first = 0x0B56, .last = 0x0B56 },
        .{ .first = 0x0B82, .last = 0x0B82 },
        .{ .first = 0x0BC0, .last = 0x0BC0 },
        .{ .first = 0x0BCD, .last = 0x0BCD },
        .{ .first = 0x0C3E, .last = 0x0C40 },
        .{ .first = 0x0C46, .last = 0x0C48 },
        .{ .first = 0x0C4A, .last = 0x0C4D },
        .{ .first = 0x0C55, .last = 0x0C56 },
        .{ .first = 0x0CBC, .last = 0x0CBC },
        .{ .first = 0x0CBF, .last = 0x0CBF },
        .{ .first = 0x0CC6, .last = 0x0CC6 },
        .{ .first = 0x0CCC, .last = 0x0CCD },
        .{ .first = 0x0CE2, .last = 0x0CE3 },
        .{ .first = 0x0D41, .last = 0x0D43 },
        .{ .first = 0x0D4D, .last = 0x0D4D },
        .{ .first = 0x0DCA, .last = 0x0DCA },
        .{ .first = 0x0DD2, .last = 0x0DD4 },
        .{ .first = 0x0DD6, .last = 0x0DD6 },
        .{ .first = 0x0E31, .last = 0x0E31 },
        .{ .first = 0x0E34, .last = 0x0E3A },
        .{ .first = 0x0E47, .last = 0x0E4E },
        .{ .first = 0x0EB1, .last = 0x0EB1 },
        .{ .first = 0x0EB4, .last = 0x0EB9 },
        .{ .first = 0x0EBB, .last = 0x0EBC },
        .{ .first = 0x0EC8, .last = 0x0ECD },
        .{ .first = 0x0F18, .last = 0x0F19 },
        .{ .first = 0x0F35, .last = 0x0F35 },
        .{ .first = 0x0F37, .last = 0x0F37 },
        .{ .first = 0x0F39, .last = 0x0F39 },
        .{ .first = 0x0F71, .last = 0x0F7E },
        .{ .first = 0x0F80, .last = 0x0F84 },
        .{ .first = 0x0F86, .last = 0x0F87 },
        .{ .first = 0x0F90, .last = 0x0F97 },
        .{ .first = 0x0F99, .last = 0x0FBC },
        .{ .first = 0x0FC6, .last = 0x0FC6 },
        .{ .first = 0x102D, .last = 0x1030 },
        .{ .first = 0x1032, .last = 0x1032 },
        .{ .first = 0x1036, .last = 0x1037 },
        .{ .first = 0x1039, .last = 0x1039 },
        .{ .first = 0x1058, .last = 0x1059 },
        .{ .first = 0x1160, .last = 0x11FF },
        .{ .first = 0x135F, .last = 0x135F },
        .{ .first = 0x1712, .last = 0x1714 },
        .{ .first = 0x1732, .last = 0x1734 },
        .{ .first = 0x1752, .last = 0x1753 },
        .{ .first = 0x1772, .last = 0x1773 },
        .{ .first = 0x17B4, .last = 0x17B5 },
        .{ .first = 0x17B7, .last = 0x17BD },
        .{ .first = 0x17C6, .last = 0x17C6 },
        .{ .first = 0x17C9, .last = 0x17D3 },
        .{ .first = 0x17DD, .last = 0x17DD },
        .{ .first = 0x180B, .last = 0x180D },
        .{ .first = 0x18A9, .last = 0x18A9 },
        .{ .first = 0x1920, .last = 0x1922 },
        .{ .first = 0x1927, .last = 0x1928 },
        .{ .first = 0x1932, .last = 0x1932 },
        .{ .first = 0x1939, .last = 0x193B },
        .{ .first = 0x1A17, .last = 0x1A18 },
        .{ .first = 0x1B00, .last = 0x1B03 },
        .{ .first = 0x1B34, .last = 0x1B34 },
        .{ .first = 0x1B36, .last = 0x1B3A },
        .{ .first = 0x1B3C, .last = 0x1B3C },
        .{ .first = 0x1B42, .last = 0x1B42 },
        .{ .first = 0x1B6B, .last = 0x1B73 },
        .{ .first = 0x1DC0, .last = 0x1DCA },
        .{ .first = 0x1DFE, .last = 0x1DFF },
        .{ .first = 0x200B, .last = 0x200F },
        .{ .first = 0x202A, .last = 0x202E },
        .{ .first = 0x2060, .last = 0x2063 },
        .{ .first = 0x206A, .last = 0x206F },
        .{ .first = 0x20D0, .last = 0x20EF },
        .{ .first = 0x302A, .last = 0x302F },
        .{ .first = 0x3099, .last = 0x309A },
        .{ .first = 0xA806, .last = 0xA806 },
        .{ .first = 0xA80B, .last = 0xA80B },
        .{ .first = 0xA825, .last = 0xA826 },
        .{ .first = 0xFB1E, .last = 0xFB1E },
        .{ .first = 0xFE00, .last = 0xFE0F },
        .{ .first = 0xFE20, .last = 0xFE23 },
        .{ .first = 0xFEFF, .last = 0xFEFF },
        .{ .first = 0xFFF9, .last = 0xFFFB },
        .{ .first = 0x10A01, .last = 0x10A03 },
        .{ .first = 0x10A05, .last = 0x10A06 },
        .{ .first = 0x10A0C, .last = 0x10A0F },
        .{ .first = 0x10A38, .last = 0x10A3A },
        .{ .first = 0x10A3F, .last = 0x10A3F },
        .{ .first = 0x1D167, .last = 0x1D169 },
        .{ .first = 0x1D173, .last = 0x1D182 },
        .{ .first = 0x1D185, .last = 0x1D18B },
        .{ .first = 0x1D1AA, .last = 0x1D1AD },
        .{ .first = 0x1D242, .last = 0x1D244 },
        .{ .first = 0xE0001, .last = 0xE0001 },
        .{ .first = 0xE0020, .last = 0xE007F },
        .{ .first = 0xE0100, .last = 0xE01EF },
    };

    // test for 8-bit control characters
    if (ucs == 0)
        return 0;
    if (ucs < 32 or (ucs >= 0x7f and ucs < 0xa0))
        return 0;

    // binary search in table of non-spacing characters
    if (bisearch(ucs, combining, combining.len - 1))
        return 0;

    // if we arrive here, ucs is not a combining or C0/C1 control character

    return 1 + @as(u3, @intFromBool(ucs >= 0x1100 and
        (ucs <= 0x115f or // Hangul Jamo init. consonants
            ucs == 0x2329 or ucs == 0x232a or
            (ucs >= 0x2e80 and ucs <= 0xa4cf and
                ucs != 0x303f) or // CJK ... Yi
            (ucs >= 0xac00 and ucs <= 0xd7a3) or // Hangul Syllables
            (ucs >= 0xf900 and ucs <= 0xfaff) or // CJK Compatibility Ideographs
            (ucs >= 0xfe10 and ucs <= 0xfe19) or // Vertical forms
            (ucs >= 0xfe30 and ucs <= 0xfe6f) or // CJK Compatibility Forms
            (ucs >= 0xff00 and ucs <= 0xff60) or // Fullwidth Forms
            (ucs >= 0xffe0 and ucs <= 0xffe6) or
            (ucs >= 0x20000 and ucs <= 0x2fffd) or
            (ucs >= 0x30000 and ucs <= 0x3fffd))));
}
