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
    cmd: fn (args: [][]const u8, param: anytype) ProcessError!void = undefined,
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

const JsonWriter = struct {
    const Self = @This();

    file: std.fs.File = undefined,

    pub const Writer = std.io.Writer(*Self, error{OutOfMemory}, write);

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub fn write(self: JsonWriter, data: []const u8) !usize {
        return try self.file.write(data);
    }
};

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

    var new_file: bool = false;
    var file_name: []const u8 = "config.json";

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

    const edit_range_data: Process = Process{
        .name = "range",
        .help = "range <range#> <channel, start, length>",
        .cmd = struct {
            fn editRangeData(arg: [][]const u8, line: anytype) ProcessError!void {
                const sout = std.io.getStdOut().writer();

                if (arg.len != 2) {
                    sout.print("Format must be: {s}\n", .{"range <range#> <channel, start, length>"}) catch return;
                    return ProcessError.WrongFormat;
                }

                const range_num = std.fmt.parseUnsigned(u32, arg[0], 10) catch {
                    sout.print("Please input a number for the range.\n", .{}) catch return;
                    return ProcessError.NotANumber;
                } - 1;

                const mod = arg[1];

                if (range_num < 0 or range_num >= line.*.ranges.len) {
                    sout.print("Range number must be between 1 and {d}", .{line.*.ranges.len}) catch return;
                    return ProcessError.OutOfRange;
                }

                var buffer: [1024]u8 = undefined;

                if (std.mem.eql(u8, mod, "channel")) {
                    var new_channel_str: []const u8 = undefined;

                    while (true) {
                        new_channel_str = readInput("Please input a new channel number (1~4): ", &buffer) catch "err";
                        _ = std.fmt.parseUnsigned(u2, new_channel_str, 10) catch {
                            sout.print("Please input a correct number for the channel # (1~4).\n", .{}) catch return;
                            continue;
                        };
                        break;
                    }
                    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer aa.deinit();

                    const new_channel_concat = std.fmt.allocPrint(aa.allocator(), "cc_link_{s}slot", .{new_channel_str}) catch return;

                    line.*.ranges[range_num].channel = @field(mcl.connection.Channel, new_channel_concat);

                    sout.print("Range #{d} channel num changed to {s}\n", .{ range_num, new_channel_str }) catch return;
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
        .help = "line <line#> <name, axes, ranges>",
        .cmd = struct {
            fn editLineData(arg: [][]const u8, con: anytype) ProcessError!void {
                const sout = std.io.getStdOut().writer();

                if (arg.len != 2) {
                    sout.print("Format must be: {s}\n", .{"line <line#> <name, axes, ranges>"}) catch return;
                    return ProcessError.WrongFormat;
                }

                for (con[0].*.modules[0].mcl.lines, 0..) |line, i| {
                    sout.print("axes: {d}\n", .{line.axes}) catch return;
                    sout.print("{d}. name:{s}\n", .{ i, con[0].*.modules[0].mcl.line_names[i] }) catch return;
                    sout.print("ranges:\n", .{}) catch return;
                    for (line.ranges) |range| {
                        sout.print("  start: {d}\n", .{range.start}) catch return;
                        sout.print("  channel: {s}\n", .{range.channel}) catch return;
                        sout.print("  length: {d}\n\n", .{range.length}) catch return;
                    }
                }

                const line_num = std.fmt.parseUnsigned(u32, arg[0], 10) catch {
                    sout.print("Please input a number for the line #.\n", .{}) catch return;
                    return ProcessError.NotANumber;
                } - 1;
                const mod = arg[1];

                const lines: []mcl.Config.Line = con[0].*.modules[0].mcl.lines;

                if (line_num < 0 or line_num >= lines.len) {
                    sout.print("Line number must be between 1 and {d}.\n", .{lines.len}) catch return;
                    return ProcessError.OutOfRange;
                }

                var buffer: [1024]u8 = undefined;

                if (std.mem.eql(u8, mod, "name")) {
                    const new_name = readInput("Please input the new name", &buffer) catch return;
                    con[0].*.modules[0].mcl.line_names[line_num] = new_name;

                    save_config(con[2], con[0], con[1]); //TODO do this better. numbers confusing

                    sout.print("Line #{d} name changed to {s}.\n", .{ line_num, new_name }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "axes")) {
                    const new_axes: u10 = std.fmt.parseUnsigned(u10, readInput("Please input a new axes", &buffer) catch "err", 10) catch {
                        sout.print("Please input a number.\n", .{}) catch return;
                        return ProcessError.NotANumber;
                    };

                    con[0].*.modules[0].mcl.lines[line_num].axes = new_axes;
                    save_config(con[2], con[0], con[1]);

                    sout.print("Line #{d} axes changed to {d}\n", .{ line_num, new_axes }) catch return;
                    return;
                } else if (std.mem.eql(u8, mod, "ranges")) {
                    runProcess(edit_range_data, &con[0].*.modules[0].mcl.lines[line_num]) catch return;
                    save_config(con[2], con[0], con[1]);
                    sout.print("Range data successfully saved.\n", .{}) catch return;
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
                    sout.print("Format must be: {s}\n", .{"add <name> <axes> (inputting ranges will come after)"}) catch return;
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

                var num_of_range: u32 = 1;
                outer: while (true) : (num_of_range += 1) {
                    sout.print("Range #{d}\n", .{num_of_range}) catch return;
                    const channel = readInput("Please input the channel #. (1~4)", &buffer) catch return;
                    _ = std.fmt.parseUnsigned(u2, channel, 10) catch {
                        sout.print("Please input a correct number for the channel # (1~4).\n", .{}) catch return;
                        num_of_range -= 1;
                        continue;
                    };

                    const start = std.fmt.parseUnsigned(u32, readInput("Please input the start #.", &buffer) catch "err", 10) catch {
                        sout.print("Please input a number for the start #.\n", .{}) catch return;
                        num_of_range -= 1;
                        continue;
                    };
                    const end = std.fmt.parseUnsigned(u32, readInput("Please input the end #.", &buffer) catch "err", 10) catch {
                        sout.print("Please input a number for the end #.\n", .{}) catch return;
                        num_of_range -= 1;
                        continue;
                    };

                    var aa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer aa.deinit();

                    const new_channel_concat = std.fmt.allocPrint(aa.allocator(), "cc_link_{s}slot", .{channel}) catch return;

                    ranges.append(mcl.Config.Line.Range{
                        .channel = @field(mcl.connection.Channel, new_channel_concat),
                        .start = start,
                        .end = end,
                    });

                    sout.print("New range created.\n", .{}) catch return;
                    sout.print("channel: {s}\n", .{new_channel_concat}) catch return;
                    sout.print("start: {}", .{start}) catch return;
                    sout.print("end: {}\n", .{end}) catch return;

                    while (true) {
                        const cont = readInput("Add another range? [y/n]", &buffer) catch return;
                        if (std.mem.eql(u8, cont, "y")) {
                            continue :outer;
                        } else if (std.mem.eql(u8, cont, "n")) {
                            break :outer;
                        } else {
                            sout.print("Allowed inputs are [y/n]\n", .{}) catch return;
                        }
                    }
                }

                con[0].*.modules[0].mcl.lines = con[0].*.modules[0].mcl.lines ++ .{mcl.Config.Line{ .axes = axes, .ranges = ranges }};
                con[0].*.modules[0].mcl.line_names = con[0].*.modules[0].mcl.line_names ++ .{name};

                save_config(con[2], con[0], con[1]);

                sout.print("Successfully created a new line.\n", .{}) catch return;
                //TODO: formatted print the newly created line.
            }
        }.addLineData,
    };

    var buffer: [1024]u8 = undefined;

    while (true) {
        if (new_file) {
            const input = try readInput("Please input a name for the new config json file:", &buffer);

            file_name = input;
        }

        const run = try readInput("Modify or add data? [y/n]", &buffer);

        if (std.mem.eql(u8, run, "y")) {
            const m_or_a = try readInput("m for modify, a for add", &buffer);

            if (std.mem.eql(u8, m_or_a, "m")) {
                try runProcess(edit_line_data, .{ &config, new_file, file_name });
            } else if (std.mem.eql(u8, m_or_a, "a")) {
                try runProcess(add_line_data, .{ &config, new_file, file_name });
            }
            new_file = false;
        } else if (std.mem.eql(u8, run, "n")) {
            try stdout.print("Quitting program.\n", .{});
            break;
        } else {
            try stdout.print("Wrong input\n", .{});
        }
    }
    return 0;
}

fn save_config(file_name: []const u8, config: Config, new_file: bool) !void {
    var json_writer = JsonWriter{ .file = if (new_file) try std.fs.cwd().createFile(file_name, .{}) else try std.fs.cwd().openFile(file_name, .{}) };

    defer json_writer.file.close();
    try std.json.stringify(config, .{}, json_writer.writer());
}
