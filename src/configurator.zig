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
    channel: *mcl.connection.Channel,
    @"[]Config.Line": *[]mcl.Config.Line,
    @"[]Config.Line.Range": *[]mcl.Config.Line.Range,
};

//thin wrapper for Node
const Tree = struct {
    root: Node,

    fn init(field_name: []const u8) Tree {
        return Tree{ .root = Node.init(field_name) };
    }

    fn deinit(self: Tree) void {
        for (self.root.nodes.items) |node| {
            node.deinit();
        }
        self.root.nodes.deinit();
    }

    fn navigate_tree(self: *Tree, action_history: std.ArrayList([]const u8)) !*Tree.Node {
        var cur_node: *Tree.Node = @constCast(&self.root);

        if (action_history.items.len != 0) {
            std.log.debug("1{s}\n", .{action_history.items[0]});
        }

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

            cur_node = self.root.find_child(first, num) orelse return error.ChildNotFound;
        }
        if (action_history.items.len != 0) {
            std.log.debug("2{s}\n", .{action_history.items[0]});
        }
        return cur_node;
    }

    const Node = struct {
        nodes: std.ArrayList(Node),
        is_array: bool = false,

        ptr: ?AnyPointer = null, //i want to use this for the getValue function and keep it null if it's not applicable, but there's probably a better way
        field_name: []const u8,
        getValue: ?*const fn (*Node) anyerror!void = null, //function to read input from user and update value.
        field_value: []const u8 = "",

        fn init(field_name: []const u8) Node {
            var arr_list = std.ArrayList(Node).init(std.heap.page_allocator);
            arr_list = arr_list; //is there a way to not do this.
            return Node{
                .nodes = arr_list,
                .field_name = field_name,
            };
        }

        fn deinit(self: Node) void {
            for (self.nodes.items) |child| {
                child.deinit();
            }
            self.nodes.deinit();
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

    var ll = [2]mcl.Config.Line{ create_default_line(), create_default_line() };

    config.modules[0].mcl.lines = &ll;

    var buffer: [1024]u8 = undefined;

    if (new_file) {
        const input = try readInput("Please input the new config file name:", &buffer);
        file_name = input;
    }

    var tree = Tree.init("mcl");
    const lines = &config.modules[0].mcl.lines;

    _ = try fillTree(&tree.root, @TypeOf(lines.*), @ptrCast(lines), "lines");

    defer tree.deinit();

    var action_stack = std.ArrayList([]const u8).init(std.heap.page_allocator);

    defer action_stack.deinit();

    //TODO make ability to add new stuff, not just modify.
    while (true) {
        if (action_stack.items.len != 0) {
            std.log.debug("hoi {s}", .{action_stack.items[0]});
        }
        const cur_node = try tree.navigate_tree(action_stack);

        try cur_node.print("", null);

        if (cur_node.getValue) |func| {
            //if getValue function is not null, which means it's a modifiable field
            if (func(cur_node)) {
                //TODO save to file
                action_stack.clearRetainingCapacity(); //hmm
            } else |_| continue;
        } else {
            while (true) : ({
                try stdout.print("\n\n\n", .{});
                try cur_node.print("", null);
                if (action_stack.items.len != 0) {
                    std.log.debug("pop {s}", .{action_stack.items[0]});
                }
            }) {
                const input = try readInput("Please select the field you want to modify:", &buffer);

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
                        const @"♩¨̮(ง ˙˘˙ )ว♩¨̮" = "happy";
                        try stdout.print("{s}\n", .{@"♩¨̮(ง ˙˘˙ )ว♩¨̮"});
                    } else {
                        try stdout.print("You can only add items to lists.\n", .{});
                    }
                } else {
                    var split = std.mem.splitSequence(u8, input, " ");
                    const node_name = split.next().?;
                    var node_num: ?u64 = null;

                    if (cur_node.is_array) {
                        if (split.next()) |num_str| {
                            node_num = try std.fmt.parseUnsigned(u64, num_str, 10);
                        } else {
                            try stdout.print("Please add the '{s}' number you want to modify.\n", .{cur_node.field_name});
                            continue;
                        }
                    }

                    const next_node = cur_node.find_child(node_name, node_num);

                    if (next_node) |_| {
                        try action_stack.append(input);
                    } else {
                        try stdout.print("Could not find field. Try again.\n", .{});
                    }

                    break;
                }
            }
            try stdout.print("\n\n\n", .{});
        }
    }

    return 0;
}

fn fillTree(parent: ?*Tree.Node, comptime T: type, source_ptr: *anyopaque, source_name: []const u8) !Tree.Node {
    const casted_ptr: *T = @alignCast(@ptrCast(source_ptr));
    const source = casted_ptr.*;

    const stdout = std.io.getStdOut().writer();
    var head = Tree.Node.init(source_name);

    switch (@typeInfo(T)) {
        .Pointer => |pointerInfo| {
            switch (pointerInfo.size) {
                .Slice => {
                    if (source.len != 0) {
                        switch (@typeInfo(@TypeOf(source[0]))) {
                            .Int => |intInfo| {
                                if (intInfo.bits == 8 and intInfo.signedness == .unsigned) {
                                    //String
                                    head.ptr = AnyPointer{ .str = casted_ptr };
                                    head.getValue = setStr;
                                    head.field_value = casted_ptr.*;
                                } else {
                                    head.is_array = true;
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
                                        _ = try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1] ++ i); //remove the 's' at the end to convert to singular form
                                    }
                                }
                            },

                            else => {
                                head.is_array = true;
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

                                for (casted_ptr.*) |*item| {
                                    _ = try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1]); //remove the 's' at the end to convert to singular form
                                }
                            },
                        }
                    }
                    if (parent) |p| {
                        try p.nodes.append(head); //im pretty sure data gets copied to the arraylist, not store a pointer to it ¯\_(ツ)_/¯
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
            inline for (structInfo.fields) |field| {
                const val_ptr = &@field(casted_ptr.*, field.name);
                _ = try fillTree(&head, field.type, @ptrCast(val_ptr), field.name);
            }
            if (parent) |p| {
                try p.nodes.append(head);
            }
            return head;
        },

        .Array => {
            try stdout.print("{s}\n", .{source_name});
        },

        else => {
            switch (@typeInfo(T)) {
                .Int => |info| {

                    //TODO: fix. turns out field_value is pointing at buf and doesn't actually own a copy of the data, so it get's lost :(
                    var buf: [256]u8 = undefined;
                    const str = try std.fmt.bufPrint(&buf, "{}", .{casted_ptr.*});
                    head.field_value = str;

                    //TODO: refactor
                    switch (info.bits) {
                        8 => {
                            head.ptr = AnyPointer{ .u8 = casted_ptr };
                            head.getValue = setU8;
                        },

                        10 => {
                            head.ptr = AnyPointer{ .u10 = casted_ptr };
                            head.getValue = setU10;
                        },

                        32 => {
                            head.ptr = AnyPointer{ .u32 = casted_ptr };
                            head.getValue = setU32;
                        },

                        else => {
                            try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                            return error.UnsupportedType;
                        },
                    }
                    if (parent) |p| {
                        try p.nodes.append(head);
                    }

                    return head; //doesnt really matter
                },

                .Enum => {
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

fn setStr(node: *Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;

    try stdout.print("Please input a new value for {s}.\n", .{node.field_name});

    const input = try readInput("", &buffer);
    const prev_val = node.ptr.?.str.*;
    node.ptr.?.str.* = input;

    try stdout.print("Changed value from {s} to {s}/\n", .{ prev_val, input });
}

fn setChannel(node: *Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a new channel number. (1~4)\n", &buffer);

    const num = std.fmt.parseUnsigned(u2, input, 10) catch |err| {
        try stdout.print("Please input a correct channel number.\n", .{});
        return err;
    }; //this will automatically handle cases where numbers are > 4 because it's a u2.

    node.ptr.?.channel.* = @as(mcl.connection.Channel, @enumFromInt(num - 1));
    try stdout.print("Channel successfully changed\n", .{});
}

fn setU8(node: *Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u8, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u8.* = num;
    try stdout.print("Number value successfully changed.\n", .{});
}

fn setU32(node: *Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u32, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u32.* = num;
    try stdout.print("Number value successfully changed.\n", .{});
}

fn setU10(node: *Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();

    var buffer: [1024]u8 = undefined;
    const input = try readInput("Please input a number.", &buffer);

    const num = std.fmt.parseUnsigned(u10, input, 10) catch |err| {
        try stdout.print("Please input a correct number.\n", .{});
        return err;
    };

    node.ptr.?.u10.* = num;
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
        .channel = mcl.Config.connection.Channel{.cc_link_1slot},
        .start = 0,
        .end = 0,
    };
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
