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

fn readInput(out: []const u8) ![]u8 {
    try std.io.getStdOut().writer().print("{s}\n", .{out});
    //TODO: implement user input
    return "";
}

fn printConfigLines(config: Config) void {
    const lines: []mcl.Config.Line = config.modules[0].mcl.lines;
    const line_names: [][]const u8 = config.modules[0].mcl.line_names;
    const stdout = std.io.getStdOut().writer();

    //print all the lines
    for (lines, 0..) |line, i| {
        try stdout.print("{d}. name:{s}\n", .{ i, line_names[i] });
        try stdout.print("axes: {d}\n", .{line.axes});
        try stdout.print("ranges:\n");
        try stdout.print("  channel: {s}\n", .{line.ranges.channel});
        try stdout.print("  start: {d}\n", .{line.ranges.start});
        try stdout.print("  length: {d}\n\n", .{line.ranges.length});
    }

    var line_number = std.fmt.parseUnsigned(u32, readInput(""), 10) - 1 catch {
        stdout.print("Cannot parse to int\n", .{});
        return;
    };

    while (line_number < 0 or line_number >= lines.len) {
        try stdout.print("Line # must be between 1 and {d}\n", .{lines.len});
        line_number = std.fmt.parseUnsigned(u32, readInput(""), 10) - 1 catch {
            stdout.print("Cannot parse to int\n", .{});
            return;
        };
    }
}

fn changeData(config: *Config) !void {
    try std.io.getStdOut().writer().print("Changing existing data.\n", .{});
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout = std.io.getStdOut().writer();

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
        config = config_parse.value;
    } else {
        config.modules = try allocator.alloc(Config.Module.Config, 1);
        config.modules[0] = .{ .mcl = .{
            .line_names = &.{},
            .lines = &.{},
        } };
    }

    // Main interaction loop.
    while (true) {
        const run = try readInput("Modify file? [y/n]");

        if (std.mem.eql(u8, run, "y")) {
            try changeData(&config);
        } else if (std.mem.eql(u8, run, "n")) {
            try stdout.print("Quitting program\n", .{});
        } else try stdout.print("Wrong input\n", .{});
    }

    return 0;
}
