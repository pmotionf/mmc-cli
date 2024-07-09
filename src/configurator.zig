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
    u8: *u8,
    u32: *u32,
    channel: *mcl.connection.Channel,
};

const TreeNode = struct {
    value: Value = val,
    nodes: std.ArrayList(TreeNode) = std.ArrayList(TreeNode).init(std.heap.page_allocator), //is a new instance of the list created each time? or would every TreeNode use the same ArrayList
    ptr: ?AnyPointer = ptr, //i want to use this for the getValue function and keep it null if it's not applicable, but there's probably a better way

    const Value = union(enum) {
        field_name: []const u8,
        getValue: fn (AnyPointer) anyerror!void, //function to read input from user and update value.
    };

    fn deinit(self: TreeNode) void {
        self.nodes.deinit();
    }
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

    var head = TreeNode{
        .value = TreeNode.Value{ .field_name = "mcl" },
        .ptr = null,
    };

    //for this to work, config needs to be built in comptime.
    fillTree(&head, @TypeOf(config.modules[0].mcl.lines), config.modules[0].mcl.lines);

    return 0;
}

fn fillTree(parent: *TreeNode, comptime T: type, source: anytype) void {
    switch (@typeInfo(T)) {
        .Array => |arrayInfo| {
            switch (try source.peekNextTokenType()) {
                .array_begin => {
                    //Typical array
                    var head = TreeNode{
                        .value = TreeNode.Value{.field_name = @typeName(T)},
                        .ptr = null,
                    };

                    for(0..arrayInfo.len) |i| {
                        fillTree(&head, arrayInfo.child, source);
                    }
                    parent.nodes.append(head);
                },

                .string => {
                    //String
                    //if the lines and the line_names are separated, the user won't be able to see informations about the line they are modifying in this structure. is that fine?
                },
            }
        },

        .Struct => |structInfo| {
            var r: T = undefined;

            var head = TreeNode{
                .value = TreeNode.Value{.field_name = }
            }
        },

        else => {
            //Just a normal field.
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

fn setStartOrEnd(ptr: AnyPointer) !void {
    _ = ptr;
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
