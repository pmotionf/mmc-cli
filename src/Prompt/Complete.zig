//! Prompt autocompletion.
const Complete = @This();

const std = @import("std");

const command = @import("../command.zig");

/// Currently in-progress partial input, used for matches against completions.
/// Unowned memory; this will *not* be freed by this module.
partial: []const u8 = &.{},

/// Longest common prefix of all current suggestions.
prefix: []const u8 = &.{},

/// Dynamically updated suggestions, filtered and ordered as partial grows.
/// Each suggestion is unowned, and will *not* be freed by this module.
suggestions: [][]const u8 = &.{},
suggestions_buffer: [512][]const u8 = undefined,

kind: Kind,

pub const Kind = enum {
    command,
    variable,
};

/// Sets completion partial and recalculates suggestions. Completion kind must
/// be set before the partial is set.
pub fn setPartial(self: *Complete, partial: []const u8) void {
    self.partial = partial;
    self.prefix = &.{};
    self.suggestions = &.{};

    if (partial.len == 0) return;

    // Store suggestions, unordered.
    switch (self.kind) {
        .command => {
            for (command.registry.values()) |c| {
                if (c.name.len <= partial.len) continue;
                if (!std.ascii.startsWithIgnoreCase(c.name, partial))
                    continue;

                self.suggestions_buffer[self.suggestions.len] = c.name;
                self.suggestions =
                    self.suggestions_buffer[0 .. self.suggestions.len + 1];
            }
        },
        .variable => {
            var var_it = command.variables.iterator();
            while (var_it.next()) |entry| {
                const var_name = entry.key_ptr.*;
                if (var_name.len <= partial.len) continue;
                if (!std.mem.startsWith(u8, var_name, partial))
                    continue;

                self.suggestions_buffer[self.suggestions.len] = var_name;
                self.suggestions =
                    self.suggestions_buffer[0 .. self.suggestions.len + 1];
            }
        },
    }

    if (self.suggestions.len == 0) return;
    if (self.suggestions.len == 1) {
        self.prefix = self.suggestions[0];
        return;
    }

    // Order suggestions.
    std.mem.sortUnstable(
        []const u8,
        self.suggestions,
        {},
        lengthPrioritizedLessThan,
    );

    self.prefix = lcp(
        self.suggestions[0],
        self.suggestions[self.suggestions.len - 1],
    );
}

/// Returns longest common prefix of two strings as a slice of LHS.
fn lcp(lhs: []const u8, rhs: []const u8) []const u8 {
    const min_len = @min(lhs.len, rhs.len);

    for (lhs[0..min_len], rhs[0..min_len], 0..) |l, r, i| {
        if (l != r) {
            return lhs[0..i];
        }
    }

    return lhs;
}

fn lengthPrioritizedLessThan(
    _: void,
    lhs: []const u8,
    rhs: []const u8,
) bool {
    if (lhs.len < rhs.len) return true;
    if (rhs.len > lhs.len) return false;

    return std.mem.lessThan(u8, lhs, rhs);
}
