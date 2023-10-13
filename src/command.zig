const std = @import("std");

pub var registry: std.StringArrayHashMap(Command) = undefined;
pub var stop: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false);

var variables: std.BufMap = undefined;
var command_queue: std.ArrayList(CommandString) = undefined;

const CommandString = struct {
    buffer: [1024]u8,
    len: usize,
};

pub const Command = struct {
    /// Name of a command, as shown to/parsed from user.
    name: []const u8,
    /// List of argument names. Each argument should be wrapped in a "()" for
    /// required arguments, or "[]" for optional arguments.
    parameters: []const Parameter = &[_]Command.Parameter{},
    /// Short description of command.
    short_description: []const u8,
    /// Long description of command.
    long_description: []const u8,
    execute: *const fn ([][]const u8) anyerror!void,

    pub const Parameter = struct {
        name: []const u8,
        optional: bool = false,
        quotable: bool = true,
        resolve: bool = true,
    };
};

pub fn init() !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    allocator = arena.allocator();

    registry = std.StringArrayHashMap(Command).init(allocator);
    variables = std.BufMap.init(allocator);
    command_queue = std.ArrayList(CommandString).init(allocator);

    try registry.put("HELP", .{
        .name = "HELP",
        .parameters = &[_]Command.Parameter{
            .{ .name = "Command", .resolve = false },
        },
        .short_description = "Display detailed information about a command.",
        .long_description =
        \\Print a detailed description of a command's purpose, use, and other
        \\such aspects of consideration. A valid command name must be provided.
        ,
        .execute = &help,
    });
    try registry.put("VERSION", .{
        .name = "VERSION",
        .short_description = "Display the version of the MCS CLI.",
        .long_description =
        \\Print the currently running version of the Motion Control Software
        \\command line utility in Semantic Version format.
        ,
        .execute = &version,
    });
    try registry.put("SET", .{
        .name = "SET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "Variable", .resolve = false },
            .{ .name = "Value" },
        },
        .short_description = "Set a variable equal to a value.",
        .long_description =
        \\Create a variable name that resolves to the provided value in all
        \\future commands. Variable names are case sensitive.
        ,
        .execute = &set,
    });
    try registry.put("GET", .{
        .name = "GET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "Variable", .resolve = false },
        },
        .short_description = "Retrieve the value of a variable.",
        .long_description =
        \\Retrieve the resolved value of a previously created variable name.
        \\Variable names are case sensitive.
        ,
        .execute = &get,
    });
    try registry.put("EXIT", .{
        .name = "EXIT",
        .short_description = "Exit the MCS command line utility.",
        .long_description =
        \\Gracefully terminate the PMF Motion Control Software command line
        \\utility, cleaning up resources and closing connections.
        ,
        .execute = &exit,
    });
}

pub fn deinit() void {
    variables.deinit();
    command_queue.deinit();
    registry.deinit();
    arena.deinit();
}

pub fn queueEmpty() bool {
    return command_queue.items.len == 0;
}

pub fn queueClear() void {
    command_queue.clearRetainingCapacity();
}

pub fn enqueue(input: []const u8) !void {
    var buffer = CommandString{
        .buffer = undefined,
        .len = undefined,
    };
    @memcpy(buffer.buffer[0..input.len], input);
    buffer.len = input.len;
    try command_queue.insert(0, buffer);
}

pub fn execute() !void {
    const cb = command_queue.pop();
    std.log.info("Running command: {s}", .{cb.buffer[0..cb.len]});
    try parseAndRun(cb.buffer[0..cb.len]);
}

fn parseAndRun(input: []const u8) !void {
    var token_iterator = std.mem.tokenizeSequence(u8, input, " ");
    var command: *Command = undefined;
    var command_buf: [32]u8 = undefined;
    if (token_iterator.next()) |token| {
        if (registry.getPtr(std.ascii.upperString(
            &command_buf,
            token,
        ))) |c| {
            command = c;
        } else return error.InvalidCommand;
    } else return;

    var params: [][]const u8 = try allocator.alloc(
        []const u8,
        command.parameters.len,
    );
    defer allocator.free(params);

    for (command.parameters, 0..) |param, i| {
        const _token = token_iterator.peek();
        defer _ = token_iterator.next();
        if (_token == null) {
            if (param.optional) {
                params[i] = "";
            } else return error.MissingParameter;
        }
        var token = _token.?;

        // Resolve variables.
        if (param.resolve) {
            if (variables.get(token)) |val| {
                token = val;
            }
        }

        if (param.quotable) {
            if (token[0] == '"') {
                const start_ind: usize = token_iterator.index + 1;
                var len: usize = 0;
                while (token_iterator.next()) |tok| {
                    if (tok[tok.len - 1] == '"') {
                        // 2 subtracted from length to account for the two
                        // quotation marks.
                        len += tok.len - 2;
                        break;
                    }
                    // Because the token was consumed with `.next`, the index
                    // here will be the start index of the next token.
                    len = token_iterator.index - start_ind;
                }
                params[i] = input[start_ind .. start_ind + len];
            } else params[i] = token;
        } else {
            params[i] = token;
        }
    }
    if (token_iterator.peek() != null) return error.UnexpectedParameter;
    try command.execute(params);
}

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

fn help(params: [][]const u8) !void {
    var command: *Command = undefined;
    var command_buf: [32]u8 = undefined;

    if (params[0].len > 32) return error.InvalidCommand;

    if (registry.getPtr(std.ascii.upperString(
        &command_buf,
        params[0],
    ))) |c| {
        command = c;
    } else return error.InvalidCommand;
    std.log.info("\nDetailed information for command {s}:\n{s}\n", .{
        command.name,
        command.long_description,
    });
}

fn version(_: [][]const u8) !void {
    // TODO: Figure out better way to get version from `build.zig.zon`.
    std.log.info("MCS CLI: {s}", .{"0.0.2"});
}

fn set(params: [][]const u8) !void {
    try variables.put(params[0], params[1]);
}

fn get(params: [][]const u8) !void {
    if (variables.get(params[0])) |value| {
        std.log.info("Variable \"{s}\": {s}", .{
            params[0],
            value,
        });
    } else return error.UndefinedVariable;
}

fn exit(_: [][]const u8) !void {
    std.os.exit(1);
}
