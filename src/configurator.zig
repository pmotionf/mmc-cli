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

    const Node = struct {
        nodes: std.ArrayList(TreeNode),
        ptr: ?AnyPointer = null, //i want to use this for the getValue function and keep it null if it's not applicable, but there's probably a better way
        field_name: []const u8,
        getValue: ?*const fn (AnyPointer) void = null, //function to read input from user and update value.

        fn init(field_name: []const u8) void {
            var arr_list = std.ArrayList(Node).init(std.heap.page_allocator);
            arr_list = arr_list; //is there a way to not do this.
            return Node{
                .nodes = arr_list,
                .field_name = field_name,
            };
        }

        fn deinit(self: TreeNode) void {
            self.nodes.deinit();
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

    var head = Tree.init("mcl");
    const lines = &config.modules[0].mcl.lines;

    //for this to work, config needs to be built in comptime.
    try fillTree(&head, @TypeOf(lines.*), @ptrCast(lines), "lines");

    return 0;
}

fn fillTree(parent: *Tree.Node, comptime T: type, source_ptr: *anyopaque, source_name: []const u8) !void {
    var casted_ptr: *T = @alignCast(@ptrCast(source_ptr));
    const source = casted_ptr.*;

    switch (@typeInfo(T)) {
        .Array => |arrayInfo| {
            var head = Tree.Node.init(source_name);

            if (arrayInfo.len != 0) {
                if (isSpecificInteger(@TypeOf(source[0]), 8, .unsigned)) {
                    //String
                    //if the lines and the line_names are separated, the user won't be able to see informations about the line they are modifying in this structure. is that fine?
                } else {
                    for (source) |item| {
                        try fillTree(&head, arrayInfo.child, item, source_name[0 .. source_name.len - 1]); //remove the 's' at the end to convert to singular form
                    }
                }
            }
            try parent.nodes.append(head);
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
            var end_node = Tree.Node.init("");

            switch (@typeInfo(T)) {
                .Int => {
                    if (isSpecificInteger(T, 8, .unsigned)) {
                        //modifying start

                    }
                },
            }
        },
    }
}

fn setLineName(ptr: AnyPointer) !void {
    _ = ptr;
}

fn setAxes(ptr: AnyPointer) !void {
    _ = ptr;
}

fn setChannel(ptr: AnyPointer) !void {
    _ = ptr;
}

fn setStart(ptr: AnyPointer) !void {
    _ = ptr;
}

fn setEnd(ptr: AnyPointer) !void {
    _ = ptr;
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
