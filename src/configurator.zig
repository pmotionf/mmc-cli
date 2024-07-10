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

    fn navigate_tree(self: Tree, action_history: std.ArrayList([]const u8)) !Tree.Node {
        var cur_node: Tree.Node = self.root;
        for (action_history.items) |name| {
            var split = std.mem.splitSequence(u8, name, " ");
            const first = split.next().?;
            var num: ?u64 = undefined;

            if (split.next()) |n| {
                num = try std.fmt.parseUnsigned(u64, n, 10);
            } else {
                num = null;
            }

            cur_node = self.root.find_child(first, num) orelse return error.ChildNotFound;
        }
        return cur_node;
    }

    const Node = struct {
        nodes: std.ArrayList(Node),
        is_array: bool = false,

        ptr: ?AnyPointer = null, //i want to use this for the getValue function and keep it null if it's not applicable, but there's probably a better way
        field_name: []const u8,
        getValue: ?*const fn (Node) anyerror!void = null, //function to read input from user and update value.

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

        fn find_child(self: Tree.Node, name: []const u8, num: ?u64) ?Tree.Node {
            for (self.nodes.items, 0..) |node, i| {
                if (num) |n| {
                    if (std.mem.eql(u8, node.field_name, name) and n == i) {
                        return node;
                    }
                } else {
                    if (std.mem.eql(u8, node.field_name, name)) {
                        return node;
                    }
                }
            }
            return null; //could not find node with given name and/or index #.
        }

        //prints the current node as well as all of its descendents.
        fn print(self: Tree.Node, indents: []const u8, num: ?u64) !void {
            const stdout = std.io.getStdOut().writer();

            var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer aa.deinit();
            const indented_print = try std.fmt.allocPrint(aa.allocator(), "{s}{s}:\n", .{ indents, self.field_name });

            try stdout.print("{s}", .{indented_print});

            for (self.nodes.items, 0..) |node, i| {
                const j = @as(u64, i);
                if (num) |n| {
                    try print(node, try std.fmt.allocPrint(aa.allocator(), "{d}. {s}    ", .{ n, indents }), if (self.is_array) j else null);
                } else {
                    try print(node, try std.fmt.allocPrint(aa.allocator(), "{s}    ", .{indents}), if (self.is_array) j else null);
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

    var buffer: [1024]u8 = undefined;

    if (new_file) {
        const input = try readInput("Please input the new config file name:", &buffer);
        file_name = input;
    }

    var tree = Tree.init("mcl");
    const lines = &config.modules[0].mcl.lines;

    try fillTree(&tree.root, @TypeOf(lines.*), @ptrCast(lines), "lines");

    //TODO change this to an arraylist of splits so you don't have to calculate the second argument in two places
    var action_stack = std.ArrayList([]const u8).init(std.heap.page_allocator);

    // defer tree.deinit();s

    //TODO make ability to add new stuff, not just modify.
    while (true) {
        const cur_node = try tree.navigate_tree(action_stack);

        try cur_node.print("", null);

        if (cur_node.getValue) |func| {
            //if getValue function is not null, which means it's a modifiable field
            if (func(cur_node)) {
                //TODO save to file
                action_stack.clearRetainingCapacity(); //hmm. i want to send the user back to the main screen but also be able to go back but that's kinda difficult with this format.
            } else |_| continue;
        } else {
            while (true) : ({
                try stdout.print("\n\n\n", .{});
                try cur_node.print("", null);
            }) {
                const input = try readInput("Please select a field to modify or type 'add' to add a new item.", &buffer);

                var split = std.mem.splitSequence(u8, input, " ");
                const node_name = split.next().?;
                var node_num: ?u64 = undefined;

                if (cur_node.is_array) {
                    if (split.next()) |num_str| {
                        node_num = try std.fmt.parseUnsigned(u64, num_str, 10);
                    } else {
                        try stdout.print("Please add the '{s}' number you want to modify.\n", .{cur_node.field_name});
                        continue;
                    }
                }
                //If it's not a number, then just ignore all the arguments the user put afterwards.

                //TODO add a quit command
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
                } else if (cur_node.find_child(node_name, node_num)) |_| {
                    try action_stack.append(input);
                    break;
                } else {
                    try stdout.print("Could not find field. Try again.\n", .{});
                }
            }
            try stdout.print("\n\n\n", .{});
        }
    }
    return 0;
}

fn fillTree(parent: *Tree.Node, comptime T: type, source_ptr: *anyopaque, source_name: []const u8) !void {
    const casted_ptr: *T = @alignCast(@ptrCast(source_ptr));
    const source = casted_ptr.*;

    const stdout = std.io.getStdOut().writer();

    //TODO refactor. 3 nested switches (; ꒪ö꒪)
    switch (@typeInfo(T)) {
        .Pointer => |pointerInfo| {
            switch (pointerInfo.size) {
                .Slice => {
                    var head = Tree.Node.init(source_name);
                    head.is_array = true;
                    @field(head.ptr.?, @typeName(T)) = casted_ptr;

                    if (source.len != 0) {
                        switch (@typeInfo(@TypeOf(source[0]))) {
                            .Int => |intInfo| {
                                if (intInfo.bits == 8 and intInfo.signedness == .unsigned) {
                                    //String
                                    head.ptr = AnyPointer{ .str = casted_ptr };
                                    head.getValue = setStr;
                                } else {
                                    //TODO i don't want to put this piece of code in two places
                                    for (casted_ptr.*, 0..) |*item, i| {
                                        try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1] ++ i); //remove the 's' at the end to convert to singular form
                                    }
                                }
                            },

                            else => {
                                for (source) |*item| {
                                    try fillTree(&head, @TypeOf(source[0]), @ptrCast(item), source_name[0 .. source_name.len - 1]); //remove the 's' at the end to convert to singular form
                                }
                            },
                        }
                    }
                    try parent.nodes.append(head); //im pretty sure data gets copied to the arraylist, not store a pointer to it ¯\_(ツ)_/¯
                },

                else => {
                    try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                    return error.UnsupportedType;
                },
            }
        },

        .Struct => |structInfo| {
            var head = Tree.Node.init(source_name);

            inline for (structInfo.fields) |field| {
                const val_ptr = &@field(casted_ptr.*, field.name);
                try fillTree(&head, field.type, @ptrCast(val_ptr), field.name);
            }
            try parent.nodes.append(head);
        },

        else => {
            var end_node = Tree.Node.init(source_name);
            switch (@typeInfo(T)) {
                .Int => |info| {

                    //TODO: refactor
                    switch (info.bits) {
                        8 => {
                            end_node.ptr = AnyPointer{ .u8 = casted_ptr };
                            end_node.getValue = setU8;
                        },

                        10 => {
                            end_node.ptr = AnyPointer{ .u10 = casted_ptr };
                            end_node.getValue = setU10;
                        },

                        32 => {
                            end_node.ptr = AnyPointer{ .u32 = casted_ptr };
                            end_node.getValue = setU32;
                        },

                        else => {
                            try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                            return error.UnsupportedType;
                        },
                    }
                },

                .Enum => {
                    end_node.ptr = AnyPointer{ .channel = casted_ptr };
                    end_node.getValue = setChannel;
                },

                else => {
                    try stdout.print("Unsupported type: {}\n", .{@typeInfo(T)});
                    return error.UnsupportedType;
                },
            }
        },
    }
}

fn setStr(node: Tree.Node) !void {
    const stdout = std.io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;

    try stdout.print("Please input a new value for {s}.\n", .{node.field_name});

    const input = try readInput("", &buffer);
    const prev_val = node.ptr.?.str.*;
    node.ptr.?.str.* = input;

    try stdout.print("Changed value from {s} to {s}/\n", .{ prev_val, input });
}

fn setChannel(node: Tree.Node) !void {
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

fn setU8(node: Tree.Node) !void {
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

fn setU32(node: Tree.Node) !void {
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

fn setU10(node: Tree.Node) !void {
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
