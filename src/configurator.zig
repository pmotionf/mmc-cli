const std = @import("std");
const args = @import("args");
const Config = @import("Config.zig");
const mcl = @import("mcl");

const ProcessError = error{
    WrongFormat,
    NotANumber,
    OutOfRange,
};

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

const Process = struct {
    name: []const u8,
    cmd: fn (args: [][]const u8, param: anytype) ProcessError!void = undefined, //returning 1 means there was some error, so run the command again. If 0 is returned, then the "command loop" is exited,
    help: []const u8 = undefined,
};

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

fn runProcess(cmd: Process, param: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    var buffer: [1024]u8 = undefined;

    while (true) {
        try stdout.print("{s}\n", .{cmd.help});

        const input = try readInput("", &buffer);
        var input_split = std.mem.splitSequence(u8, input, " ");
        const cmd_name: []const u8 = input_split.next().?;

        if (std.mem.eql(u8, cmd_name, cmd.name)) {
            const allocator = std.heap.page_allocator;
            var rest = std.ArrayList([]const u8).init(allocator);
            defer rest.deinit();

            while (input_split.next()) |n| {
                try rest.append(n);
            }

            const cmd_args: [][]const u8 = rest.items;

            if (cmd.cmd(cmd_args, param)) |_| {
                break;
            } else |_| {
                continue;
            }
        } else {
            try stdout.print("Command name is {s}.\n", .{cmd.name});
            continue;
        }
    }
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

    const edit_range_data: Process = Process{
        .name = "range",
        .help = "range <range#> <channel, start, length>",
        .cmd = struct {
            fn editRangeData(arg: [][]const u8, line: anytype) ProcessError!void {
                const sout = std.io.getStdOut().writer();

                if (arg.len != 2) {
                    sout.print("Format must be: {s}\n", .{"TODO: add help message here"}) catch return;
                    return ProcessError.WrongFormat;
                }

                const range_num = std.fmt.parseUnsigned(u32, arg[0], 10) - 1 catch {
                    sout.print("Please input a number for the range.\n", .{}) catch return;
                    return ProcessError.NotANumber;
                };

                const mod = arg[1];

                if (range_num < 0 or range_num >= line.*.ranges.len) {
                    sout.print("Range number must be between 1 and {d}", .{line.*.ranges.len}) catch return;
                    return ProcessError.OutOfRange;
                }

                var buffer: [1024]u8 = undefined;

                if (std.mem.eql(u8, mod, "channel")) {
                    const new_channel = readInput("Please input a new channel name: ", &buffer) catch return;

                    line.*.ranges.channel = "cc_link_" ++ new_channel ++ "slot";

                    sout.print("Range #{d} channel name changed to {s}\n", .{ range_num, line.*.ranges.channel }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "start")) {
                    const new_start = std.fmt.parseUnsigned(u32, readInput("Please input a new start #.", &buffer) catch "err") catch {
                        sout.print("Please input a number for the start #.", .{}) catch return;
                        return ProcessError.NotANumber;
                    };

                    line.*.ranges.start = new_start;
                    sout.print("Range #{d} start # changed to {d}\n", .{ range_num, new_start }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "start")) {
                    const new_length = std.fmt.parseUnsigned(u32, readInput("Please input a new length.", &buffer) catch "err") catch {
                        sout.print("Please input a number for the length #.", .{}) catch return;
                        return ProcessError.NotANumber;
                    };

                    line.*.ranges.length = new_length;
                    sout.print("Range #{d} length # changed to {d}\n", .{ range_num, new_length }) catch return;
                    return;
                } else {
                    sout.print("Second argument must be channel, start, or length.\n", .{}) catch return;
                    return ProcessError.WrongFormat;
                }
            }
        }.editRangeData,
    };

    const edit_line_data: Process = Process{
        .name = "line",
        .help = "line <line#> <name, axes, ranges>", //TODO: make the help message print out the informations about the existing lines.
        .cmd = struct {
            fn editLineData(arg: [][]const u8, con: anytype) ProcessError!void {
                const sout = std.io.getStdOut().writer();

                if (arg.len != 2) {
                    sout.print("Format must be: {s}\n", .{"TODO: add help message here"}) catch return;
                    return ProcessError.WrongFormat;
                }

                const line_num = std.fmt.parseUnsigned(u32, arg[0], 10) catch {
                    sout.print("Please input a number for the line #.\n", .{}) catch return;
                    return ProcessError.NotANumber;
                } - 1;
                const mod = arg[1];

                const lines: []mcl.Config.Line = con.*.modules[0].mcl.lines;

                if (line_num < 0 or line_num >= lines.len) {
                    sout.print("Line number must be between 1 and {d}.\n", .{lines.len}) catch return;
                    return ProcessError.OutOfRange;
                }

                var buffer: [1024]u8 = undefined;

                if (std.mem.eql(u8, mod, "name")) {
                    const new_name = readInput("Please input the new name", &buffer) catch return;
                    con.*.modules[0].mcl.line_names[line_num] = new_name;

                    sout.print("Line #{d} name changed to {s}.\n", .{ line_num, new_name }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "axes")) {
                    const new_axes: u8 = std.fmt.parseUnsigned(u32, readInput("Please input a new axes", &buffer) catch "err") catch {
                        sout.print("Please input a number.\n", .{}) catch return;
                        return ProcessError.NotANumber;
                    };

                    con.*.modules[0].mcl.lines[line_num].axes = new_axes;

                    sout.print("Line #{d} axes changed to {d}\n", .{ line_num, new_axes }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "ranges")) {
                    runProcess(edit_range_data, &con.*.modules[0].mcl.lines[line_num]) catch return;
                    return;
                }
            }
        }.editLineData,
    };

    const add_line_data: Process = Process{
        .name = "add",
        .help = "add <name> <axes> (inputting ranges will come after)",
        .cmd = struct {
            fn addLineData(arg: [][]const u8, con: anytype) ProcessError!void {
                const sout = std.io.getStdOut().writer();

                if (arg.len != 2) {
                    sout.print("Format must be: {s}\n", .{"TODO put the help message here."}) catch return;
                    return ProcessError.WrongFormat;
                }

                var buffer: [1024]u8 = undefined;

                const name = readInput("Please input the line name.", &buffer) catch return;
                const axes = std.fmt.parseUnsigned(u32, arg[1], 10) catch {
                    sout.print("Line axes # must be a number.\n", .{}) catch return;
                    return ProcessError.NotANumber;
                };

                const alloc = std.heap.page_allocator;
                var ranges = std.ArrayList(mcl.Config.Line.Range).init(alloc);
                defer ranges.deinit();

                comptime var num_of_range = 1;
                while (true) : (num_of_range += 1) {
                    sout.print("Range #{d}\n", .{num_of_range}) catch return;
                    const channel = try readInput("Please input the channel name.", &buffer);
                    const start = std.fmt.parseUnsigned(u32, readInput("Please input the start #.", &buffer) catch "err") catch {
                        sout.print("Please input a number for the start #.\n", .{}) catch return;
                        num_of_range -= 1;
                        continue;
                    };
                    const length = std.fmt.parseUnsigned(u32, readInput("Please input the length.", &buffer) catch "err") catch {
                        sout.print("Please input a number for the length.\n", .{}) catch return;
                        num_of_range -= 1;
                        continue;
                    };

                    ranges.append(mcl.Config.Line.Range{
                        .channel = "cc_link_" ++ channel ++ "slot",
                        .start = start,
                        .length = length,
                    });

                    sout.print("New range created.\n", .{}) catch return; //TODO: formatted print the newly added range.

                    const cont = readInput("Add another range? [y/n]", &buffer) catch return;

                    if (std.mem.eql(u8, cont, "y")) {
                        continue;
                    } else if (std.mem.eql(u8, cont, "n")) {
                        break;
                    }
                    //TODO: reask the above question if something else is inputted
                }

                con.*.modules[0].mcl.lines = con.*.modules[0].mcl.lines ++ .{mcl.Config.Line{ .axes = axes, .ranges = ranges }};
                con.*.modules[0].mcl.line_names = con.*.modules[0].mcl.line_names ++ .{name};

                sout.print("Successfully created a new line.\n", .{}) catch return;
                //TODO: formatted print the newly created line.
            }
        }.addLineData,
    };

    var buffer: [1024]u8 = undefined;

    while (true) {
        const run = try readInput("Modify or add data? [y/n]", &buffer);

        if (std.mem.eql(u8, run, "y")) {
            const m_or_a = try readInput("m for modify, a for add", &buffer);

            if (std.mem.eql(u8, m_or_a, "m")) {
                try runProcess(edit_line_data, &config);
            } else if (std.mem.eql(u8, m_or_a, "a")) {
                try runProcess(add_line_data, &config);
            }
        } else if (std.mem.eql(u8, run, "n")) {
            try stdout.print("Quitting program.\n", .{});
            break;
        } else {
            try stdout.print("Wrong input\n", .{});
        }
    }
    return 0;
}

// fn rangeToJson(range: mcl.Config.Line.Range, alloc: *std.mem.Allocator) !std.json.Value{
//     std.json.stringify()
// }
