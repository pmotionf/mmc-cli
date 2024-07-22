const std = @import("std");
const args = @import("args");
const Config = @import("Config.zig");
const mcl = @import("mcl");
const command = @import("command/mcl.zig");

const Options = struct {
    create: bool = false,
    help: bool = false,
    output: []const u8 = "config.json",

    pub const shorthands = .{
        .c = "create",
        .h = "help",
        .o = "output",
    };

    pub const meta = .{
        .option_docs = .{
            .create = "create new configuration file",
            .help = "print this help message",
            .output = "configuration output path, defaults to \"config.json\"",
        },
    };
};

const AnyPointer = union(enum) {
    str: *[]const u8,
    u8: *u8, //start
    u32: *u32, //end
    u10: *u10, //axes
    u64: *u64,
    channel: *mcl.connection.Channel,
    @"[]Config.Line": *[]mcl.Config.Line,
    @"[]Config.Line.Range": *[]mcl.Config.Line.Range,

    fn which(self: AnyPointer) []const u8 {
        switch (self) {
            .str => return "str",
            .u8 => return "u8",
            .u32 => return "u32",
            .u10 => return "u10",
            .channel => return "channel",
            .@"[]Config.Line" => return "lines",
            .@"[]Config.Line.Range" => return "ranges",
        }
    }
};

//thin wrapper for Node
const Tree = struct {
    root: Node,

    fn init(field_name: []const u8) Tree {
        return Tree{ .root = Node.init(field_name) };
    }

    fn deinit(self: Tree, alloc: std.mem.Allocator) void {
        for (self.root.nodes.items) |node| {
            node.deinit(alloc);
        }
        self.root.nodes.deinit();
    }

    fn navigate_tree(self: *Tree, action_history: std.ArrayList([]const u8)) !*Tree.Node {
        var cur_node: *Tree.Node = @constCast(&self.root);

        for (0..action_history.items.len) |i| {
            const name = action_history.items[i];

            var split = std.mem.splitSequence(u8, name, " ");
            const first = split.next().?;
            const num_str: ?[]const u8 = split.next();
            var num: ?u64 = undefined;

            if (num_str != null and !std.mem.eql(u8, num_str.?, "")) {
                num = try std.fmt.parseUnsigned(u64, num_str.?, 10);
            } else {
                num = null;
            }

            cur_node = cur_node.find_child(first, num) orelse return error.ChildNotFound;
        }

        return cur_node;
    }

    const Node = struct {
        nodes: std.ArrayList(Node),
        is_array: bool = false,

        ptr: ?AnyPointer = null, //i want to use this for the getValue function and keep it null if it's not applicable, but there's probably a better way
        field_name: []const u8,
        getValue: ?*const fn (*Node, std.mem.Allocator) anyerror!void = null, //function to read input from user and update value.
        field_value: []const u8 = "",

        fn init(field_name: []const u8) Node {
            var arr_list = std.ArrayList(Node).init(std.heap.page_allocator);
            arr_list = arr_list; //is there a way to not do this.
            return Node{
                .nodes = arr_list,
                .field_name = field_name,
            };
        }

        fn deinit(self: Node, alloc: std.mem.Allocator) void {
            for (self.nodes.items) |child| {
                child.deinit(alloc);
            }
            self.nodes.deinit();
            alloc.free(self.field_value);
        }

        fn find_child(self: Tree.Node, name: []const u8, num: ?u64) ?*Tree.Node {
            for (self.nodes.items, 0..) |*node, i| {
                if (num) |n| {
                    if (std.mem.eql(u8, node.field_name, name) and n - 1 == i) {
                        return node;
                    }
                } else {
                    if (std.mem.eql(u8, node.field_name, name)) {
                        return node;
                    }
                }
            }
            return null; //could not find node with given name.
        }

        //prints the current node as well as all of its descendents.
        fn print(self: Tree.Node, indents: []const u8, num: ?u64) !void {
            const stdout = std.io.getStdOut().writer();

            if (num) |n| {
                try stdout.print("{s}{d}. {s}: {s}\n", .{ indents, n, self.field_name, self.field_value });
            } else {
                try stdout.print("{s}{s}: {s}\n", .{ indents, self.field_name, self.field_value });
            }

            var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer aa.deinit();

            for (self.nodes.items, 0..) |node, i| {
                const j = @as(u64, i);

                if (self.is_array) {
                    try print(node, try std.fmt.allocPrint(aa.allocator(), "{s}    ", .{indents}), j + 1);
                } else {
                    try print(node, try std.fmt.allocPrint(aa.allocator(), "{s}    ", .{indents}), null);
                }
            }
        }
    };
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    var new_file: bool = false;
    var file_name: []const u8 = undefined;

    const options = args.parseForCurrentProcess(
        Options,
        allocator,
        .print,
    ) catch return 1;
    defer options.deinit();

    if (options.options.help) {
        try args.printHelp(
            Options,
            options.executable_name orelse "configurator",
            stdout,
        );
        return 0;
    }

    var config: Config = .{
        .modules = &.{},
    };

    if (!options.options.create) {
        if (options.positionals.len != 1) {
            try args.printHelp(
                Options,
                options.executable_name orelse "configurator",
                stdout,
            );
            return error.OneExistingConfigFilePathRequired;
        }
        var config_file = try std.fs.cwd().openFile(
            options.positionals[0],
            .{},
        );
        defer config_file.close();
        const config_parse = try Config.parse(allocator, config_file);
        file_name = options.positionals[0];
        config = config_parse.value;
    } else {
        new_file = true;
        config.modules = try allocator.alloc(Config.Module.Config, 1);
        config.modules[0] = .{ .mcl = .{
            .line_names = &.{},
            .lines = &.{},
        } };
    }
    // Load existing config file.

    var line = [1]mcl.Config.Line{create_default_line()};

    config.modules[0].mcl.lines = &line;

    var buffer: [1024]u8 = undefined;

    if (new_file) {
        const input = try readInput("Please input the new config file name:", &buffer);
        file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{input});
        try save_config(file_name, config);
    }

    var tree = Tree.init("mcl");
    const lines = &config.modules[0].mcl.lines;

    _ = try fillTree(&tree.root, @TypeOf(lines.*), @ptrCast(lines), "lines", allocator);

    defer tree.deinit(allocator);

    var action_stack = std.ArrayList([]const u8).init(std.heap.page_allocator);

    defer action_stack.deinit();

    //TODO make ability to add new stuff, not just modify.
    while (true) {
        const cur_node = try tree.navigate_tree(action_stack);

        if (cur_node.ptr) |p| {
            try stdout.print("yeah: {s}\n", .{p.which()});
        }

        try cur_node.print("", null);

        if (cur_node.getValue) |func| {
            //if getValue function is not null, which means it's a modifiable field
            if (func(cur_node, allocator)) {
                try save_config(file_name, config);
                action_stack.clearRetainingCapacity(); //hmm
            } else |_| continue;
        } else {
            while (true) : ({
                try stdout.print("\n\n\n", .{});
                try cur_node.print("", null);
            }) {
                const input = try readInput("Please select the field you want to modify:", &buffer);
                var split = std.mem.splitSequence(u8, input, " ");

                const first_arg = split.next().?;

                //TODO add a quit command
                //TODO add a remove command
                if (std.mem.eql(u8, input, "prev")) {
                    if (action_stack.items.len != 0) {
                        _ = action_stack.pop();
                        try stdout.print("Going to previous page.\n", .{});
                        break;
                    } else {
                        try stdout.print("There's no more page history.\n", .{});
                    }
                } else if (std.mem.eql(u8, input, "add")) {
                    if (cur_node.is_array) {
                        if (std.mem.eql(u8, cur_node.field_name, "lines")) {
                            var new_line = [1]mcl.Config.Line{create_default_line()};
                            const added_lines = try allocator.alloc(mcl.Config.Line, config.modules[0].mcl.lines.len + 1);
                            std.mem.copyForwards(mcl.Config.Line, added_lines, config.modules[0].mcl.lines);
                            copyStartingFromIndex(mcl.Config.Line, added_lines, &new_line, config.modules[0].mcl.lines.len);

                            config.modules[0].mcl.lines = added_lines;
                            var new_line_ptr: *mcl.Config.Line = undefined;

                            if (cur_node.nodes.items.len == 0) {
                                try stdout.print("zero\n", .{});
                                new_line_ptr = @as(*mcl.Config.Line, @ptrCast(config.modules[0].mcl.lines.ptr));
                            } else {
                                try stdout.print("more\n", .{});
                                new_line_ptr = @as(*mcl.Config.Line, @ptrCast(config.modules[0].mcl.lines.ptr + (config.modules[0].mcl.lines.len - 2)));
                            }

                            const new_node = try fillTree(null, mcl.Config.Line, new_line_ptr, "line", allocator);
                            try cur_node.nodes.append(new_node);

                            try save_config(file_name, config);
                        } else if (std.mem.eql(u8, cur_node.field_name, "ranges")) {
                            var new_range = [1]mcl.Config.Line.Range{create_default_range()};
                            const added_ranges = try allocator.alloc(mcl.Config.Line.Range, cur_node.ptr.?.@"[]Config.Line.Range".len + 1);
                            std.mem.copyForwards(mcl.Config.Line.Range, added_ranges, cur_node.ptr.?.@"[]Config.Line.Range".*);
                            copyStartingFromIndex(mcl.Config.Line.Range, added_ranges, &new_range, cur_node.ptr.?.@"[]Config.Line.Range".len);

                            cur_node.ptr.?.@"[]Config.Line.Range" = @constCast(&added_ranges);
                            var new_line_ptr: *mcl.Config.Line.Range = undefined;

                            if (cur_node.nodes.items.len == 0) {
                                new_line_ptr = @as(*mcl.Config.Line.Range, @ptrCast(cur_node.ptr.?.@"[]Config.Line.Range".ptr));
                            } else {
                                new_line_ptr = @as(*mcl.Config.Line.Range, @ptrCast(cur_node.ptr.?.@"[]Config.Line.Range".ptr + (cur_node.ptr.?.@"[]Config.Line.Range".len - 2)));
                            }

                            const new_node = try fillTree(null, mcl.Config.Line.Range, new_line_ptr, "range", allocator);
                            try cur_node.nodes.append(new_node);

                            try save_config(file_name, config);
                        }
                    } else {
                        try stdout.print("You can only add items to lists.\n", .{});
                    }
                } else if (std.mem.eql(u8, first_arg, "remove")) {
                    if (cur_node.is_array) {
                        if (cur_node.nodes.items.len == 0) {
                            try stdout.print("There is nothing to remove.\n", .{});
                            continue;
                        }

                        const next_split = split.next();
                        var num_str: []const u8 = undefined;
                        if (next_split == null) {
                            try stdout.print("Please specify the number for the item you want to remove.\n", .{});
                            continue;
                        } else {
                            num_str = next_split.?;
                        }

                        const num = std.fmt.parseUnsigned(u64, num_str, 10) catch {
                            try stdout.print("Please input a correct number.\n", .{});
                            continue;
                        };

                        if (num < 1 or num > config.modules[0].mcl.lines.len) {
                            try stdout.print("Number must be between 1 and {d}\n", .{config.modules[0].mcl.lines.len});
                            continue;
                        }

                        if (std.mem.eql(u8, cur_node.field_name, "lines")) {
                            const remove_line = try allocator.alloc(mcl.Config.Line, config.modules[0].mcl.lines.len - 1);
                            std.mem.copyForwards(mcl.Config.Line, remove_line, config.modules[0].mcl.lines[0 .. num - 1]);
                            copyStartingFromIndex(mcl.Config.Line, remove_line, config.modules[0].mcl.lines[num..config.modules[0].mcl.lines.len], num - 1);
                            allocator.free(config.modules[0].mcl.lines);

                            config.modules[0].mcl.lines = remove_line;

                            _ = cur_node.nodes.orderedRemove(num - 1);
                        } else if (std.mem.eql(u8, cur_node.field_name, "ranges")) {
                            //TODO fill
                        }

                        try save_config(file_name, config);
                    } else {
                        try stdout.print("You can only use 'remove' for lists.\n", .{});
                    }
                } else {
                    var node_num: ?u64 = null;

                    if (cur_node.is_array) {
                        if (split.next()) |num_str| {
                            node_num = std.fmt.parseUnsigned(u64, num_str, 10) catch {
                                try stdout.print("Please type in a correct number. (1~{d})\n", .{cur_node.nodes.items.len});
                                continue;
                            };
                        } else {
                            try stdout.print("Please add the '{s}' number you want to modify.\n", .{cur_node.field_name});
                            continue;
                        }
                    }

                    const next_node = cur_node.find_child(first_arg, node_num);

                    if (next_node) |_| {
                        try action_stack.append(try allocator.dupe(u8, input));
                    } else {
                        try stdout.print("Could not find field. Try again.\n", .{});
                        continue;
                    }

                    break;
                }
            }
            try stdout.print("\n\n\n", .{});
        }
    }

    return 0;
}

fn fillTree(parent: ?*Tree.Node, comptime T: type, source_ptr: *anyopaque, source_name: []const u8, allocator: ?std.mem.Allocator) !Tree.Node {
    const casted_ptr: *T = @alignCast(@ptrCast(source_ptr));
    const source = casted_ptr.*;

    const stdout = std.io.getStdOut().writer();
    var head = Tree.Node.init(source_name);

    try stdout.print("{s}\n", .{source_name});

    switch (@typeInfo(T)) {
        .Pointer => |pointerInfo| {
            switch (pointerInfo.size) {
                .Slice => {
                    try stdout.print("{}\n", .{pointerInfo.child});
                    switch (@typeInfo(@TypeOf(pointerInfo.child))) {
                        .Int => |intInfo| {
                            if (intInfo.bits == 8 and intInfo.signedness == .unsigned) {
                                //String
                                try stdout.print("string!\n", .{});
                                head.ptr = AnyPointer{ .str = casted_ptr };
                                head.getValue = setStr;
                                head.field_value = casted_ptr.*;
                            } else {
                                try stdout.print("intarr!\n", .{});
                                head.is_array = true;

                                //TODO this is wrong
                                switch (pointerInfo.child) {
                                    mcl.Config.Line => {
                                        head.ptr = AnyPointer{ .@"[]Config.Line" = casted_ptr };
                                    },

                                    mcl.Config.Line.Range => {
                                        head.ptr = AnyPointer{ .@"[]Config.Line.Range" = casted_ptr };
                                    },

                                    else => {
                                        return error.UnsupportedType;
                                    },
                                }
                                //TODO i don't want to put this piece of code in two places
                                for (casted_ptr.*, 0..) |*item, i| {
                                    //remove the 's' at the end to convert to singular form
                                    _ = try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1] ++ i, allocator);
                                }
                            }
                        },

                        else => {
                            head.is_array = true;
                            try stdout.print("array!\n", .{});
                            switch (pointerInfo.child) {
                                mcl.Config.Line => {
                                    try stdout.print("line!\n", .{});
                                    head.ptr = AnyPointer{ .@"[]Config.Line" = casted_ptr };
                                },

                                mcl.Config.Line.Range => {
                                    try stdout.print("range!!\n", .{});
                                    head.ptr = AnyPointer{ .@"[]Config.Line.Range" = casted_ptr };
                                },

                                else => {
                                    return error.UnsupportedType;
                                },
                            }

                            for (casted_ptr.*) |*item| {
                                //remove the 's' at the end to convert to singular form
                                _ = try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1], allocator);
                            }
                        },
                    }

                    if (parent) |p| {
                        try p.nodes.append(head);
                    }
                    return head;
                },

                else => {
                    try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                    return error.UnsupportedType;
                },
            }
        },

        .Struct => |structInfo| {
            try stdout.print("struct!\n", .{});
            inline for (structInfo.fields) |field| {
                const val_ptr = &@field(casted_ptr.*, field.name);
                _ = try fillTree(&head, field.type, @ptrCast(val_ptr), field.name, allocator);
            }
            if (parent) |p| {
                try p.nodes.append(head);
            }
            return head;
        },

        .Array => {
            try stdout.print("arrrrr!{s}\n", .{source_name});
        },

        else => {
            switch (@typeInfo(T)) {
                .Int => |_| {
                    try stdout.print("int!\n", .{});

                    var buf: [256]u8 = undefined;
                    const str = try std.fmt.bufPrint(&buf, "{}", .{casted_ptr.*});

                    if (allocator) |alloc| {
                        //TODO free this memory with node.free() by passing the same allocator.
                        head.field_value = try alloc.alloc(u8, str.len);
                    } else {
                        return error.MissingAllocator;
                    }
                    std.mem.copyForwards(u8, @constCast(head.field_value), str);

                    //TODO: refactor. you can probably use casting and it will works. set all num values to u64 and cast whenever needed.
                    head.ptr = AnyPointer{ .u64 = casted_ptr };
                    // switch (info.bits) {
                    //     8 => {
                    //         head.ptr = AnyPointer{ .u8 = casted_ptr };
                    //         head.getValue = setU8;
                    //     },

                    //     10 => {
                    //         head.ptr = AnyPointer{ .u10 = casted_ptr };
                    //         head.getValue = setU10;
                    //     },

                    //     32 => {
                    //         head.ptr = AnyPointer{ .u32 = casted_ptr };
                    //         head.getValue = setU32;
                    //     },

                    //     else => {
                    //         try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                    //         return error.UnsupportedType;
                    //     },
                    // }
                    if (parent) |p| {
                        try p.nodes.append(head);
                    }

                    return head; //doesnt really matter
                },

                .Enum => {
                    try stdout.print("enum!\n", .{});

                    head.field_name = @tagName(casted_ptr.*);
                    head.ptr = AnyPointer{ .channel = casted_ptr };
                    head.getValue = setChannel;
                    if (parent) |p| {
                        try p.nodes.append(head);
                    }

                    return head; //doesnt really matter
                },

                else => {
                    try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                    return error.UnsupportedType;
                },
            }
        },
    }
}

fn setStr(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    _ = alloc;
    const stdout = std.io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;

    try stdout.print("Please input a new value for {s}.\n", .{node.field_name});

    const input = try readInput("", &buffer);
    const prev_val = node.ptr.?.str.*;
    node.ptr.?.str.* = input;
    node.field_value = input;

    try stdout.print("Changed value from {s} to {s}/\n", .{ prev_val, input });
}

fn setChannel(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    _ = alloc;
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a new channel number. (0~3)\n", &buffer);

    const num = std.fmt.parseUnsigned(u2, input, 10) catch |err| {
        try stdout.print("Please input a correct channel number.\n", .{});
        return err;
    }; //this will automatically handle cases where numbers are > 3 because it's a u2.

    node.ptr.?.channel.* = @as(mcl.connection.Channel, @enumFromInt(num));
    node.field_value = @tagName(node.ptr.?.channel.*);
    try stdout.print("Channel successfully changed\n", .{});
}

fn setU8(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u8, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u8.* = num;

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{num});
    node.field_value = try alloc.alloc(u8, str.len);
    std.mem.copyForwards(u8, @constCast(node.field_value), str);

    try stdout.print("Number value successfully changed.\n", .{});
}

fn setU32(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u32, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u32.* = num;

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{num});
    node.field_value = try alloc.alloc(u8, str.len);
    std.mem.copyForwards(u8, @constCast(node.field_value), str);

    try stdout.print("Number value successfully changed.\n", .{});
}

fn setU10(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u10, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u10.* = num;

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{num});
    node.field_value = try alloc.alloc(u8, str.len);
    std.mem.copyForwards(u8, @constCast(node.field_value), str);

    try stdout.print("Number value successfully changed.\n", .{});
}

fn setU64(node: *Tree.Node, alloc: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u64, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u64.* = num;

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{num});
    node.field_value = try alloc.alloc(u8, str.len);
    std.mem.copyForwards(u8, @constCast(node.field_value), str);

    try stdout.print("Number value successfully changed.\n", .{});
}

fn isSpecificInteger(comptime T: type, comptime bits: u16, comptime signedness: std.builtin.Signedness) bool {
    return switch (@typeInfo(T)) {
        .Int => |info| info.bits == bits and info.signedness == signedness,
        else => false,
    };
}

fn create_default_line() mcl.Config.Line {
    return mcl.Config.Line{
        .axes = 0,
        .ranges = &.{},
    };
}

fn create_default_range() mcl.Config.Line.Range {
    return mcl.Config.Line.Range{
        .channel = mcl.connection.Channel.cc_link_1slot,
        .start = 0,
        .end = 0,
    };
}

///Copies slice from source to dest starting from a specified index
fn copyStartingFromIndex(comptime T: type, dest: []T, source: []T, idx: usize) void {
    for (0..dest.len - idx) |i| {
        dest[i + idx] = source[i];
    }
}

fn save_config(file_name: []const u8, config: Config) !void {
    const file = try std.fs.cwd().createFile(file_name, .{});
    defer file.close();
    try std.json.stringify(config, .{ .whitespace = .indent_tab }, file.writer());
}

fn readInput(out: []const u8, buffer: []u8) ![]const u8 {
    try std.io.getStdOut().writer().print("{s}\n", .{out});
    const reader = std.io.getStdIn().reader();

    if (try reader.readUntilDelimiterOrEof(buffer, '\n')) |value| {
        const trimmedValue = std.mem.trimRight(u8, value[0..value.len], "\r");
        return trimmedValue;
    } else {
        return "";
    }
}
