//! This module represents the interactive prompt history.
const History = @This();

const std = @import("std");

const CircularBuffer = @import("../circular_buffer.zig").CircularBuffer;

const max_buf = 1024;
const max_item_size = @import("../Prompt.zig").max_input_size;

/// Raw buffer that stores history items. Ordering not guaranteed.
items: [max_buf][max_item_size]u8 = undefined,

/// Circular buffer of history items, each a slice of `items` buffer entry.
history: CircularBuffer([]u8, max_buf) = .{},

/// Currently selected history item.
selection: ?Selection = null,

const Selection = struct {
    /// Currently selected history item as an index from history head.
    index: std.math.IntFittingRange(0, max_buf - 1),

    /// Returns current history item selection as a slice.
    pub fn slice(selection: *const Selection) []const u8 {
        const self = selection.getSelfConst();
        return self.history.buffer[
            (self.history.head + selection.index) % self.history.buffer.len
        ];
    }

    /// Selects history item prior to current selection, based on provided
    /// prefix, if available.
    pub fn previous(selection: *Selection, prefix: []const u8) void {
        if (selection.index == 0) return;
        if (prefix.len == 0) {
            selection.index -= 1;
            return;
        }

        const self = selection.getSelfConst();
        var remaining = selection.index;
        while (remaining > 0) {
            const item = self.history.buffer[
                (self.history.head + remaining - 1) % self.history.buffer.len
            ];
            if (prefix.len > item.len) continue;
            if (std.mem.eql(u8, prefix, item[0..prefix.len])) {
                selection.index = remaining - 1;
                break;
            }
            remaining -= 1;
        }
    }

    /// Selects history item after current selection, based on provided
    /// prefix, if available. If none available, unselects history.
    pub fn next(selection: *Selection, prefix: []const u8) void {
        const self = selection.getSelf();
        if (selection.index == self.history.count - 1) {
            self.selection = null;
            return;
        }
        if (prefix.len == 0) {
            selection.index += 1;
            return;
        }

        for (selection.index + 1..self.history.count) |current| {
            const item = self.history.buffer[
                (self.history.head + current) % self.history.buffer.len
            ];
            if (prefix.len > item.len) continue;
            if (std.mem.eql(u8, prefix, item[0..prefix.len])) {
                selection.index = @intCast(current);
                break;
            }
        } else {
            self.selection = null;
        }
    }

    fn getSelf(selection: *Selection) *History {
        return @alignCast(@fieldParentPtr(
            "selection",
            @as(*?Selection, @ptrCast(selection)),
        ));
    }

    fn getSelfConst(selection: *const Selection) *const History {
        return @alignCast(@fieldParentPtr(
            "selection",
            @as(*const ?Selection, @ptrCast(selection)),
        ));
    }
};

/// Selects most recent history item based on provided prefix, if available.
pub fn select(self: *History, prefix: []const u8) void {
    if (prefix.len == 0) {
        self.selection = .{ .index = @intCast(self.history.count - 1) };
        return;
    }

    var remaining = self.history.count;
    while (remaining > 0) {
        const item = self.history.buffer[
            (self.history.head + remaining - 1) %
                self.history.buffer.len
        ];
        if (prefix.len > item.len) continue;
        if (std.mem.eql(u8, prefix, item[0..prefix.len])) {
            self.selection = .{ .index = @intCast(remaining - 1) };
            break;
        }
        remaining -= 1;
    }
}

test Selection {
    var test_history: History = .{ .selection = .{ .index = 0 } };

    const parent: *History = @alignCast(@fieldParentPtr(
        "selection",
        @as(*?Selection, @ptrCast(&test_history.selection.?)),
    ));

    try std.testing.expectEqual(&test_history, parent);
}

/// Appends item to history, overwriting oldest item if history is full.
pub fn append(self: *History, item: []const u8) void {
    const insert = self.items[self.history.getWriteIndex()][0..item.len];
    @memcpy(insert, item);
    self.history.writeItemOverwrite(insert);
}

pub fn clear(self: *History) void {
    self.history.clearRetainingCapacity();
}
