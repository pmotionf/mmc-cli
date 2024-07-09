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
    channel: *mcl.connection.Channel,
};

//thin wrapper for Node
const Tree = struct {
    root: Node,

    fn init(field_name: []const u8) Tree {
        return Tree{ .root = Node.init(field_name) };
    }

    fn deinit(self: Tree) void {
        _ = self;
        //TODO deinit all arraylists inside node
    }

    fn navigate_tree(self: Tree, action_history: std.ArrayList([]const u8)) Tree.Node {
        var cur_node: Tree.Node = self.root;
        for (action_history.items) |name| {
            cur_node = self.root.find_child(name).?;
        }
        return cur_node;
    }

    const Node = struct {
        nodes: std.ArrayList(Node),
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
            self.nodes.deinit();
        }

        fn find_child(self: Tree.Node, name: []const u8) ?Tree.Node {
            for (self.nodes.items) |node| {
                if (std.mem.eql(u8, node.field_name, name)) {
                    return node;
                }
            }
            return null; //could not find node with given name.
        }

        //prints the current node as well as all of its descendents.
        fn print(self: Tree.Node, indents: []const u8) !void {
            const stdout = std.io.getStdOut().writer();

            var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer aa.deinit();
            const indented_print = try std.fmt.allocPrint(aa.allocator(), "{s}{s}:\n", .{ indents, self.field_name });

            try stdout.print("{s}", .{indented_print});

            for (self.nodes.items) |node| {
                try print(node, try std.fmt.allocPrint(aa.allocator(), "{s}    ", .{indents}));
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

    var action_stack = std.ArrayList([]const u8).init(std.heap.page_allocator);

    //TODO make ability to add new stuff, not just modify.
    while (true) {
        const cur_node = tree.navigate_tree(action_stack);

        try cur_node.print("");

        if (cur_node.getValue) |func| {
            //if getValue function is not null, which means it's a modifiable field
            if (func(cur_node)) {
                //TODO save to file
                action_stack.clearRetainingCapacity(); //hmm
            } else continue;
        } else {
            while (true) {
                const input = try readInput("Please select the field you want to modify:", &buffer);

                if (std.mem.eql(u8, input, "prev")) {
                    if (action_stack.items.len != 0) {
                        _ = action_stack.pop();
                        try stdout.print("Going to previous page.\n", .{});
                        break;
                    } else {
                        try stdout.print("There's no more page history.\n", .{});
                    }
                } else if (cur_node.find_child(input)) |_| {
                    try action_stack.append(input);
                    break;
                } else {
                    try stdout.print("Could not find field. Try again.\n", .{});
                }
            }
        }
    }

    return 0;
}

fn fillTree(parent: *Tree.Node, comptime T: type, source_ptr: *anyopaque, source_name: []const u8) !void {
    const casted_ptr: *T = @alignCast(@ptrCast(source_ptr));
    const source = casted_ptr.*;

    switch (@typeInfo(T)) {
        .Array => |arrayInfo| {
            var head = Tree.Node.init(source_name);

            if (arrayInfo.len != 0) {
                if (isSpecificInteger(@TypeOf(source[0]), 8, .unsigned)) {
                    //String
                    //if the lines and the line_names are separated, the user won't be able to see informations about the line they are modifying in this structure. is that fine?
                    head.ptr = AnyPointer{ .str = casted_ptr };
                    head.getValue = setStr;
                } else {
                    for (source) |item| {
                        try fillTree(&head, arrayInfo.child, item, source_name[0 .. source_name.len - 1]); //remove the 's' at the end to convert to singular form
                    }
                }
            }
            try parent.nodes.append(head); //im pretty sure data gets copied to the arraylist, not store a pointer to it ¯\_(ツ)_/¯
        },

        .Struct => |structInfo| {
            var head = Tree.Node.init(source_name);

            inline for (structInfo.fields) |field| {
                const val: field.type = @as(*const field.type, @alignCast(@ptrCast(field.default_value))).*;
                try fillTree(&head, field.type, val, field.name);
            }
            try parent.nodes.append(head);
        },

        else => {
            var end_node = Tree.Node.init(source_name);

            switch (@typeInfo(T)) {
                .Int => {
                    if (isSpecificInteger(T, 8, .unsigned)) {
                        //modifying start or axes
                        end_node.ptr = AnyPointer{ .u8 = casted_ptr };
                        end_node.getValue = setU8;
                    } else if (isSpecificInteger(T, 32, .unsigned)) {
                        //modifying end
                        end_node.ptr = AnyPointer{ .u32 = casted_ptr };
                        end_node.getValue = setU32;
                    }
                },

                .Enum => {
                    end_node.ptr = AnyPointer{ .channel = casted_ptr };
                    end_node.getValue = setChannel;
                },

                else => {
                    unreachable; //hopefully
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

    _ = std.fmt.parseUnsigned(u2, input, 10) catch |err| {
        try stdout.print("Please input a correct channel number.\n", .{});
        return err;
    }; //this will automatically handle cases where numbers are > 4 because it's a u2.

    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer aa.deinit();

    const new_channel_concat = try std.fmt.allocPrint(aa.allocator(), "cc_link_{s}slot", .{input});

    node.ptr.?.channel.* = @field(mcl.connection.Channel, new_channel_concat); //feels like this won't work.
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
