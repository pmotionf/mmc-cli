//! MMC client parameter type for commands specified in `mmc_client` module. Specifying parameter type in the command's parameter enable validation logic when prompting command in CLI.
const std = @import("std");
const builtin = @import("builtin");
const Line = @import("Line.zig");
const client = @import("../mmc_client.zig");
const Parameter = @This();

// TODO: Support auto completion
/// Store every parameter's possible value. Not intended to be accessed directly. Use Parameter's function as the interface for parameter value.
value: struct {
    line: LineName,
    axis: struct {
        fn isValid(_: *@This(), input: []const u8) bool {
            const axis = std.fmt.parseUnsigned(u32, input, 0) catch
                return false;
            return (axis > 0 and axis <= Line.max_axis);
        }
    },
    carrier: struct {
        fn isValid(_: *@This(), input: []const u8) bool {
            const carrier = std.fmt.parseUnsigned(u32, input, 0) catch
                return false;
            std.log.debug("valid: {}", .{carrier > 0 and carrier <= Line.max_axis});
            if (carrier > 0 and carrier <= Line.max_axis) return true;
            return false;
        }
    },
    direction: Direction,
    cas: Cas,
    link_axis: LinkAxis,
    variable: struct {
        fn isValid(_: *@This(), input: []const u8) bool {
            return std.ascii.isAlphabetic(input[0]);
        }
    },
    hall_state: hall.State,
    hall_side: hall.Side,
    filter: struct {
        fn isValid(_: *@This(), input: []const u8) bool {
            var suffix_idx: usize = 0;
            for (input) |c| {
                if (std.ascii.isDigit(c)) suffix_idx += 1 else break;
            }
            // No digit is recognized.
            if (suffix_idx == 0) return false;

            const id = std.fmt.parseUnsigned(
                u32,
                input[0..suffix_idx],
                0,
            ) catch return false; // Invalid ID
            // Check for single character suffix.
            if (input.len - suffix_idx == 1) {
                if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "a") or
                    std.ascii.eqlIgnoreCase(input[suffix_idx..], "c"))
                    return (id > 0 and id <= Line.max_axis)
                else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "d"))
                    return (id > 0 and id <= Line.max_driver)
                else
                    return false;
            }
            // Check for `axis` suffix
            else if (input.len - suffix_idx == 4 and
                std.ascii.eqlIgnoreCase(input[suffix_idx..], "axis"))
                return (id > 0 and id <= Line.max_axis)
                // Check for `carrier` suffix
            else if (std.ascii.eqlIgnoreCase(
                input[suffix_idx..],
                "carrier",
            ))
                return (id > 0 and id <= Line.max_axis)
                // Check for `driver` suffix
            else if (input.len - suffix_idx == 6 and
                std.ascii.eqlIgnoreCase(input[suffix_idx..], "driver"))
                return (id > 0 and id <= Line.max_driver)
            else
                return false;
        }
    },
    control_mode: Control,
    target: struct {
        fn isValid(_: *@This(), input: []const u8) bool {
            var suffix_idx: usize = 0;
            for (input) |c| {
                if (std.ascii.isAlphabetic(c)) break else suffix_idx += 1;
            }
            // No digit is recognized.
            if (suffix_idx == 0) return false;
            // Check for single character suffix.
            if (input.len - suffix_idx == 1) {
                if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "a")) {
                    const axis = std.fmt.parseUnsigned(
                        u32,
                        input[0..suffix_idx],
                        0,
                    ) catch return false;
                    return (axis > 0 and axis <= Line.max_axis);
                } else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "l")) {
                    _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                        return false;
                    return true;
                } else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "d")) {
                    _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                        return false;
                    return true;
                }
                return false;
            }
            // Check for `axis` suffix
            else if (input.len - suffix_idx == 4 and
                std.ascii.eqlIgnoreCase(input[suffix_idx..], "axis"))
            {
                const axis = std.fmt.parseUnsigned(
                    u32,
                    input[0..suffix_idx],
                    0,
                ) catch return false;
                return (axis > 0 and axis <= Line.max_axis);
            }
            // Check for `location` suffix
            else if (input.len - suffix_idx == 8 and
                std.ascii.eqlIgnoreCase(input[suffix_idx..], "location"))
            {
                _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                    return false;
                return true;
            }
            // Check for `distance` suffix
            else if (std.ascii.eqlIgnoreCase(input[suffix_idx..], "distance")) {
                _ = std.fmt.parseFloat(f32, input[0..suffix_idx]) catch
                    return false;
                return true;
            } else return false;
        }
    },
    log_kind: LogKind,

    const LineName = struct {
        items: std.BufSet,

        /// Initialize bufset for storing recognized line names of connected
        /// server.
        fn init(gpa: std.mem.Allocator) @This() {
            return .{ .items = std.BufSet.init(gpa) };
        }

        /// Free stored line names and invalidate the field.
        fn deinit(self: *@This()) void {
            self.items.deinit();
            self.* = undefined;
        }

        // Remove all stored lines without invalidating the field.
        fn reset(self: *@This()) void {
            var it = self.items.hash_map.iterator();
            while (it.next()) |items| {
                self.items.remove(items.key_ptr.*);
            }
            std.debug.assert(self.items.count() == 0);
        }

        /// Assert the parameter is a valid line name
        fn isValid(self: *@This(), input: []const u8) bool {
            // Invalidate if not connected to server.
            if (builtin.is_test == false and client.sock == null) return false;
            var it = std.mem.tokenizeSequence(u8, input, ",");
            while (it.next()) |item| {
                if (self.items.contains(item) == false) return false;
            }
            return true;
        }
    };

    const Direction = enum {
        forward,
        backward,

        fn isValid(_: *@This(), input: []const u8) bool {
            const ti = @typeInfo(@This()).@"enum";
            inline for (ti.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) return true;
            }
            return false;
        }
    };

    const Cas = enum {
        on,
        off,

        fn isValid(_: *@This(), input: []const u8) bool {
            const ti = @typeInfo(@This()).@"enum";
            inline for (ti.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) return true;
            }
            return false;
        }
    };

    const LinkAxis = enum {
        next,
        prev,
        right,
        left,

        fn isValid(_: *@This(), input: []const u8) bool {
            const ti = @typeInfo(@This()).@"enum";
            inline for (ti.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) return true;
            }
            return false;
        }
    };

    const hall = struct {
        const State = enum {
            on,
            off,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };

        const Side = enum {
            front,
            back,

            fn isValid(_: *@This(), input: []const u8) bool {
                const ti = @typeInfo(@This()).@"enum";
                inline for (ti.fields) |field| {
                    if (std.mem.eql(u8, field.name, input)) return true;
                }
                return false;
            }
        };
    };

    const Control = enum {
        speed,
        position,

        fn isValid(_: *@This(), input: []const u8) bool {
            const ti = @typeInfo(@This()).@"enum";
            inline for (ti.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) return true;
            }
            return false;
        }
    };

    const LogKind = enum {
        axis,
        driver,
        all,

        fn isValid(_: *@This(), input: []const u8) bool {
            const ti = @typeInfo(@This()).@"enum";
            inline for (ti.fields) |field| {
                if (std.mem.eql(u8, field.name, input)) return true;
            }
            return false;
        }
    };
},

pub const Kind = enum {
    line,
    axis,
    carrier,
    direction,
    cas,
    link_axis,
    variable,
    hall_state,
    hall_side,
    filter,
    control_mode,
    target,
    log_kind,
};
/// Initialize required memory for storing runtime-known variables. Zero
/// value initialization for comptime-known variables.
pub fn init(gpa: std.mem.Allocator) @This() {
    var res: @This() = .{
        .value = std.mem.zeroInit(
            @FieldType(Parameter, "value"),
            .{ .line = .{undefined} },
        ),
    };
    // If a field has init function, invoke init function.
    inline for (@typeInfo(@TypeOf(res.value)).@"struct".fields) |field| {
        if (@hasDecl(field.type, "init")) {
            @field(res.value, field.name) = field.type.init(gpa);
        }
    }
    return res;
}

/// Free all stored runtime-known parameters and invalidate parameter.
pub fn deinit(self: *@This()) void {
    inline for (@typeInfo(@TypeOf(self.value)).@"struct".fields) |field| {
        if (@hasDecl(field.type, "deinit")) {
            @field(self.value, field.name).deinit();
        }
    }
    self.* = undefined;
}

/// Check if the input is valid for the given kind.
pub fn isValid(self: *@This(), kind: Kind, input: []const u8) bool {
    return switch (kind) {
        inline else => |tag| @field(self.value, @tagName(tag)).isValid(input),
    };
}

/// Free all stored runtime-known parameters without invalidating the field.
pub fn reset(self: *@This()) void {
    inline for (@typeInfo(@TypeOf(self.value)).@"struct".fields) |field| {
        if (@hasDecl(field.type, "reset")) {
            @field(self.value, field.name).reset();
        }
    }
}

test "Parameter `Kind` and `value` matching" {
    const ValueType = @FieldType(Parameter, "value");
    // Check if every value fields has representation in Kind.
    inline for (@typeInfo(Parameter.Kind).@"enum".fields) |field| {
        try std.testing.expect(@hasField(ValueType, field.name));
    }
    // Check if every value`s fields have representation in Kind.
    inline for (@typeInfo(ValueType).@"struct".fields) |field| {
        try std.testing.expect(@hasField(Parameter.Kind, field.name));
    }
}

test isValid {
    var res: Parameter = .init(std.testing.allocator);
    defer res.deinit();
    // Validate line names
    try res.value.line.items.insert("left");
    try res.value.line.items.insert("right");
    try std.testing.expect(res.isValid(.line, "left"));
    try std.testing.expect(res.isValid(.line, "right"));
    try std.testing.expect(res.isValid(.line, "left,right"));
    try std.testing.expect(res.isValid(.line, "right,left"));
    try std.testing.expect(res.isValid(.line, "leftt") == false);
    // Validate axis
    try std.testing.expect(res.isValid(.axis, "768"));
    try std.testing.expect(res.isValid(.axis, "0") == false);
    try std.testing.expect(res.isValid(.axis, "769") == false);
    // Validate carrier
    try std.testing.expect(res.isValid(.carrier, "768"));
    try std.testing.expect(res.isValid(.carrier, "0") == false);
    try std.testing.expect(res.isValid(.carrier, "769") == false);
    // Validate direction
    try std.testing.expect(res.isValid(.direction, "forward"));
    try std.testing.expect(res.isValid(.direction, "backward"));
    try std.testing.expect(res.isValid(.direction, "769") == false);
    // Validate CAS
    try std.testing.expect(res.isValid(.cas, "on"));
    try std.testing.expect(res.isValid(.cas, "off"));
    try std.testing.expect(res.isValid(.cas, "forward") == false);
    // Validate link axis
    try std.testing.expect(res.isValid(.link_axis, "next"));
    try std.testing.expect(res.isValid(.link_axis, "prev"));
    try std.testing.expect(res.isValid(.link_axis, "left"));
    try std.testing.expect(res.isValid(.link_axis, "right"));
    try std.testing.expect(res.isValid(.link_axis, "forward") == false);
    // Validate variable
    try std.testing.expect(res.isValid(.variable, "next"));
    try std.testing.expect(res.isValid(.variable, "var"));
    try std.testing.expect(res.isValid(.variable, "c"));
    try std.testing.expect(res.isValid(.variable, "carrier"));
    try std.testing.expect(res.isValid(.variable, "1c") == false);
    // Validate hall state
    try std.testing.expect(res.isValid(.hall_state, "on"));
    try std.testing.expect(res.isValid(.hall_state, "off"));
    try std.testing.expect(res.isValid(.hall_state, "forward") == false);
    // Validate hall side
    try std.testing.expect(res.isValid(.hall_side, "back"));
    try std.testing.expect(res.isValid(.hall_side, "front"));
    try std.testing.expect(res.isValid(.hall_side, "forward") == false);
    // Validate filter
    try std.testing.expect(res.isValid(.filter, "1c"));
    try std.testing.expect(res.isValid(.filter, "2a"));
    try std.testing.expect(res.isValid(.filter, "d") == false);
    try std.testing.expect(res.isValid(.filter, "0.1d") == false);
    // Validate control mode
    try std.testing.expect(res.isValid(.control_mode, "speed"));
    try std.testing.expect(res.isValid(.control_mode, "position"));
    try std.testing.expect(res.isValid(.control_mode, "velocity") == false);
    // Validate target
    try std.testing.expect(res.isValid(.target, "1a"));
    try std.testing.expect(res.isValid(.target, "2l"));
    try std.testing.expect(res.isValid(.target, "3.5d"));
    try std.testing.expect(res.isValid(.target, "d") == false);
    try std.testing.expect(res.isValid(.target, "0.1a") == false);
    // Validate log kind
    try std.testing.expect(res.isValid(.log_kind, "axis"));
    try std.testing.expect(res.isValid(.log_kind, "driver"));
    try std.testing.expect(res.isValid(.log_kind, "all"));
    try std.testing.expect(res.isValid(.log_kind, "d") == false);
}
