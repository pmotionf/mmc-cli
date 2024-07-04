const std = @import("std");
const args = @import("args");
const Config = @import("Config.zig");
const mcl = @import("mcl");

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

const Prompt = struct {
    question: []const u8,
    info: []const u8,
    ptr: AnyPointer,
    field_name: []const u8,
};

const AnyPointer = union(enum) {
    @"[]mcl.Config.Line": *[]mcl.Config.Line,
    @"[]mcl.Config.Line.Range": *[]mcl.Config.Line.Range,
    @"mcl.Config.Line.Range": *mcl.Config.Line.Range,
    @"mcl.Config.Line": *mcl.Config.Line,
    @"[]const u8": *[]const u8,
    @"u8": *u8,
    @"u32": *u32,
    @"mcl.connection.Channel": *mcl.connection.Channel,
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
    // Load existing config file.
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

    var buffer: [1024]u8 = undefined;

    if (new_file) {
        const input = try readInput("Please input the new config file name:", &buffer);
        file_name = input;
    }

    const alloc = std.heap.page_allocator;
    var prompt_stack = std.ArrayList(Prompt).init(alloc);
    defer prompt_stack.deinit();

    return 0;
}

fn 

fn saveConfig(file_name: []const u8, config: *const Config) !void {
    const file: std.fs.File = std.fs.cwd().createFile(file_name, .{});
    defer file.close();
    try std.json.stringify(config.*, .{}, file.writer());
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
