//! This module defines the necessary types and functions to declare, queue,
//! and execute commands. Furthermore, it includes the implementations of a few
//! general purpose commands that facilitate easier use of the MMC CLI utility.

const std = @import("std");
const chrono = @import("chrono");
const build_zig_zon = @import("build.zig.zon");

// Command modules.
const mcl = @import("command/mcl.zig");

const Config = @import("Config.zig");

// Global registry of all commands, including from other command modules.
pub var registry: std.array_hash_map.String(Command) = .empty;

// Global "stop" flag to interrupt command execution. Command modules should
// not use this atomic flag directly, but instead prefer to use the
// `checkCommandInterrupt` to check the flag, throw a `CommandStopped` error if
// set, and then reset the flag.
pub var stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Global registry of all variables.
pub var variables: std.BufMap = undefined;

// Flags to keep track of currently initialized modules, so that only
// initialized will be deinitialized.
var initialized_modules: std.EnumArray(Config.Module, bool) = undefined;

var command_queue: std.ArrayList(CommandString) = .empty;

var timer: std.Io.Timestamp = .zero;
var clock: std.Io.Clock = .real;
var log_file: ?std.Io.File = null;
var io_command: std.Io = undefined;
var io_buf: [4096]u8 = undefined;

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
    execute: *const fn (std.Io, std.mem.Allocator, [][]const u8) anyerror!void,

    pub const Parameter = struct {
        name: []const u8,
        optional: bool = false,
        quotable: bool = true,
        resolve: bool = true,
    };
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    if (log_file) |f| {
        const file_writer = f.writer(io_command, &io_buf);
        var writer = file_writer.interface;
        writer.print("{s}({t}):", .{ level.asText(), scope }) catch {};
        writer.print(format ++ "\n", args) catch {};
        writer.flush() catch return;
    }
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    return std.log.defaultLogFileTerminal(
        level,
        scope,
        format,
        args,
        stderr,
    ) catch {};
}

pub fn init(io: std.Io, gpa: std.mem.Allocator) !void {
    io_command = io;
    initialized_modules = std.EnumArray(Config.Module, bool).initFill(false);
    variables = std.BufMap.init(gpa);
    stop.store(false, .monotonic);

    try registry.put(gpa, "HELP", .{
        .name = "HELP",
        .parameters = &[_]Command.Parameter{
            .{ .name = "command", .optional = true, .resolve = false },
        },
        .short_description = "Display detailed information about a command.",
        .long_description =
        \\Print a detailed description of a command's purpose, use, and other
        \\such aspects of consideration. A valid command name must be provided.
        \\If no command is provided, a list of all commands will be shown.
        ,
        .execute = &help,
    });
    try registry.put(gpa, "VERSION", .{
        .name = "VERSION",
        .short_description = "Display the version of the MMC CLI.",
        .long_description =
        \\Print the currently running version of the MMC command line utility
        \\in Semantic Version format.
        ,
        .execute = &version,
    });
    try registry.put(gpa, "LOAD_CONFIG", .{
        .name = "LOAD_CONFIG",
        .parameters = &[_]Command.Parameter{
            .{ .name = "file path", .optional = true },
        },
        .short_description = "Load CLI configuration file.",
        .long_description =
        \\Read given configuration file to dynamically load specified command
        \\modules. This configuration file must be in valid JSON format, with
        \\configuration parameters according to provided documentation.
        ,
        .execute = &loadConfig,
    });
    try registry.put(gpa, "WAIT", .{
        .name = "WAIT",
        .parameters = &[_]Command.Parameter{
            .{ .name = "duration", .resolve = true },
        },
        .short_description = "Pause program for given time in milliseconds.",
        .long_description =
        \\Pause command execution until the provided duration has passed in
        \\milliseconds.
        ,
        .execute = &wait,
    });
    try registry.put(gpa, "CLEAR", .{
        .name = "CLEAR",
        .parameters = &.{},
        .short_description = "Clear visible screen output.",
        .long_description = "Clear visible screen output.",
        .execute = &clear,
    });
    try registry.put(gpa, "SET", .{
        .name = "SET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "variable", .resolve = false },
            .{ .name = "value" },
        },
        .short_description = "Set a variable equal to a value.",
        .long_description =
        \\Create a variable name that resolves to the provided value in all
        \\future commands. Variable names are case sensitive.
        ,
        .execute = &set,
    });
    try registry.put(gpa, "GET", .{
        .name = "GET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "variable", .resolve = false },
        },
        .short_description = "Retrieve the value of a variable.",
        .long_description =
        \\Retrieve the resolved value of a previously created variable name.
        \\Variable names are case sensitive.
        ,
        .execute = &get,
    });
    try registry.put(gpa, "VARIABLES", .{
        .name = "VARIABLES",
        .short_description = "Display all variables with their values.",
        .long_description =
        \\Print all currently set variable names along with their values.
        ,
        .execute = &printVariables,
    });
    try registry.put(gpa, "TIMER_START", .{
        .name = "TIMER_START",
        .short_description = "Start a monotonic system timer.",
        .long_description =
        \\Start monotonic system timer. Only one timer can exist per `mmc-cli`
        \\process, thus any repeated calls to this command will simply restart
        \\the timer. This command should be run once before `TIMER_READ`.
        ,
        .execute = &timerStart,
    });
    try registry.put(gpa, "TIMER_READ", .{
        .name = "TIMER_READ",
        .short_description = "Read elapsed time from the system timer.",
        .long_description =
        \\Retreive the elapsed time from the last `TIMER_START` command. This
        \\timer is monotonic, and hence is unaffected by changing system time
        \\or timezone.
        ,
        .execute = &timerRead,
    });
    try registry.put(gpa, "FILE", .{
        .name = "FILE",
        .parameters = &[_]Command.Parameter{.{ .name = "path" }},
        .short_description = "Queue commands listed in the provided file.",
        .long_description =
        \\Add commands listed in the provided file to the front of the command
        \\queue. All queued commands will run first before the user is prompted
        \\to enter a new manual command. The queue of commands will be cleared
        \\if interrupted with the `Ctrl-C` hotkey. The file path provided for
        \\this command must be either an absolute file path or relative to the
        \\executable's directory. If the path contains spaces, it should be
        \\enclosed in double quotes (e.g. "my file path").
        ,
        .execute = &file,
    });
    try registry.put(gpa, "SAVE_OUTPUT", .{
        .name = "SAVE_OUTPUT",
        .parameters = &[_]Command.Parameter{
            .{ .name = "mode" },
            .{ .name = "path", .optional = true },
        },
        .short_description = "Save all command output after this command.",
        .long_description =
        \\Write all program logging that occurs after this command to a file.
        \\The "mode" parameter can be one of three values:
        \\  "append" - Append output to the end of the file.
        \\  "replace" - Existing file contents are overwritten with output.
        \\  "stop" - Output after this command is no longer written to a file.
        \\A file path can optionally be provided to specify the output file in
        \\cases of "append" and "replace" modes. If a path is not provided,
        \\then a default logging file containing the current system date and
        \\time will be created in the current working directory, in the format
        \\"mmc-log-YYYY.MM.DD-HH.MM.SS.txt".
        ,
        .execute = &setLog,
    });
    try registry.put(gpa, "EXIT", .{
        .name = "EXIT",
        .short_description = "Exit the MMC command line utility.",
        .long_description =
        \\Gracefully terminate the PMF MMC command line utility, cleaning up
        \\resources and closing connections.
        ,
        .execute = &exit,
    });
}

pub fn deinit(gpa: std.mem.Allocator) void {
    stop.store(true, .monotonic);
    defer stop.store(false, .monotonic);
    variables.deinit();
    command_queue.deinit(gpa);
    deinitModules();
    registry.deinit(gpa);
}

pub fn queueEmpty() bool {
    return command_queue.items.len == 0;
}

pub fn queueClear() void {
    command_queue.clearRetainingCapacity();
}

/// Checks if the `stop` flag is set, and if so returns an error.
pub fn checkCommandInterrupt() !void {
    if (stop.load(.monotonic)) {
        defer stop.store(false, .monotonic);
        queueClear();
        return error.CommandStopped;
    }
}

pub fn enqueue(gpa: std.mem.Allocator, input: []const u8) !void {
    var buffer = CommandString{
        .buffer = undefined,
        .len = undefined,
    };
    @memcpy(buffer.buffer[0..input.len], input);
    buffer.len = input.len;
    try command_queue.insert(gpa, 0, buffer);
}

pub fn execute(io: std.Io, gpa: std.mem.Allocator) !void {
    const cb = command_queue.pop().?;
    std.log.info("Running command: {s}\n", .{cb.buffer[0..cb.len]});
    try parseAndRun(io, gpa, cb.buffer[0..cb.len]);
}

fn parseAndRun(io: std.Io, gpa: std.mem.Allocator, input: []const u8) !void {
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

    var params: [][]const u8 = try gpa.alloc(
        []const u8,
        command.parameters.len,
    );
    defer gpa.free(params);

    for (command.parameters, 0..) |param, i| {
        const _token = token_iterator.peek();
        defer _ = token_iterator.next();
        if (_token == null) {
            if (param.optional) {
                params[i] = "";
                continue;
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
                    try checkCommandInterrupt();
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
    try command.execute(io, gpa, params);
}

fn help(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (params[0].len > 0) {
        var command: *Command = undefined;
        var command_buf: [32]u8 = undefined;

        if (params[0].len > 32) return error.InvalidCommand;

        if (registry.getPtr(std.ascii.upperString(
            &command_buf,
            params[0],
        ))) |c| {
            command = c;
        } else return error.InvalidCommand;

        var params_buffer: [512]u8 = .{0} ** 512;
        var params_len: usize = 0;
        for (command.parameters) |param| {
            params_len += (try std.fmt.bufPrint(
                params_buffer[params_len..],
                " {s}{s}{s}",
                .{
                    if (param.optional) "[" else "(",
                    param.name,
                    if (param.optional) "]" else ")",
                },
            )).len;
        }
        std.log.info("\n\n{s}{s}:\n{s}{s}\n{s}\n{s}{s}\n\n", .{
            command.name,
            params_buffer[0..params_len],
            "====================================",
            "====================================",
            command.long_description,
            "====================================",
            "====================================",
        });
    } else {
        for (registry.values()) |c| {
            try checkCommandInterrupt();
            var params_buffer: [512]u8 = .{0} ** 512;
            var params_len: usize = 0;
            for (c.parameters) |param| {
                params_len += (try std.fmt.bufPrint(
                    params_buffer[params_len..],
                    " {s}{s}{s}",
                    .{
                        if (param.optional) "[" else "(",
                        param.name,
                        if (param.optional) "]" else ")",
                    },
                )).len;
            }
            std.log.info("{s}{s}:\n\t{s}\n", .{
                c.name,
                params_buffer[0..params_len],
                c.short_description,
            });
        }
    }
}

fn version(_: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    std.log.info("CLI Version: {s}\n", .{build_zig_zon.version});
}

fn set(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    try variables.put(params[0], params[1]);
}

fn get(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    if (variables.get(params[0])) |value| {
        std.log.info("Variable \"{s}\": {s}\n", .{
            params[0],
            value,
        });
    } else return error.UndefinedVariable;
}

fn printVariables(_: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    var variables_it = variables.iterator();
    while (variables_it.next()) |entry| {
        try checkCommandInterrupt();
        std.log.info("\t{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn timerStart(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    timer = .now(io, clock);
}

fn timerRead(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    const duration = timer.untilNow(io, clock);
    var timer_value: f64 = @floatFromInt(duration.toMicroseconds());
    timer_value = timer_value / std.time.ns_per_s;
    // Only print to microsecond precision.
    std.log.info("Timer: {d:.6}\n", .{timer_value});
}

fn file(io: std.Io, gpa: std.mem.Allocator, params: [][]const u8) !void {
    var f = try std.Io.Dir.cwd().openFile(io, params[0], .{});
    var file_reader = f.reader(io, &.{});
    const reader = &file_reader.interface;
    const current_len: usize = command_queue.items.len;
    var new_line: CommandString = .{ .buffer = undefined, .len = 0 };
    while (true) {
        const _line = reader.takeDelimiterExclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return,
            error.ReadFailed => return file_reader.err.?,
            else => return e,
        };
        const line = std.mem.trimEnd(u8, _line, "\r");
        @memcpy(new_line.buffer[0..line.len], line);
        new_line.len = line.len;
        std.log.info("Queueing command: {s}", .{line});
        try command_queue.insert(gpa, current_len, new_line);
    }
}

fn deinitModules() void {
    var mod_it = initialized_modules.iterator();
    const fields = @typeInfo(Config.Module).@"enum".fields;
    while (mod_it.next()) |e| {
        if (e.value.*) {
            switch (@intFromEnum(e.key)) {
                inline 0...fields.len - 1 => |i| {
                    @field(@This(), fields[i].name).deinit();
                },
            }
        }
    }
}

fn loadConfig(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    // De-initialize any previously initialized modules.
    deinitModules();

    // Load config file.
    const file_path = if (params[0].len > 0) params[0] else "config.json";
    const config_file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    var m_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const m_allocator = m_arena.allocator();
    var config = try Config.parse(io, m_allocator, config_file);

    // Initialize only the modules specified in config file.
    const fields = @typeInfo(Config.Module).@"enum".fields;
    for (config.modules()) |module| {
        switch (@intFromEnum(module)) {
            inline 0...fields.len - 1 => |i| {
                try @field(@This(), fields[i].name).init(
                    @field(module, fields[i].name),
                );
                initialized_modules.set(
                    @field(Config.Module, fields[i].name),
                    true,
                );
            },
        }
    }
    config.deinit();
    m_arena.deinit();
}

fn wait(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const duration = try std.fmt.parseInt(i64, params[0], 0);
    const timestamp: std.Io.Timestamp = .now(io, clock);
    while (timestamp.untilNow(io, clock).toMilliseconds() < duration) {
        try checkCommandInterrupt();
    }
}

fn setLog(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const mode_str = params[0];
    const path = params[1];

    var buf: [512]u8 = undefined;
    const file_path = if (path.len > 0) path else p: {
        var timestamp: i64 =
            std.Io.Timestamp.now(io, std.Io.Clock.real).toSeconds();
        // var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(@divFloor(timestamp, std.time.s_per_day));
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(@rem(timestamp, std.time.s_per_day));
        const time = chrono.Time.fromNumSecondsFromMidnight(time_day, 0) catch return;

        break :p try std.fmt.bufPrint(
            &buf,
            "mmc-log-{}.{:0>2}.{:0>2}-{:0>2}.{:0>2}.{:0>2}.txt",
            .{
                ymd.year,
                ymd.month.number(),
                ymd.day,
                time.hour(),
                time.minute(),
                time.second(),
            },
        );
    };

    std.debug.print("{s}\n", .{file_path});

    if (std.ascii.eqlIgnoreCase("stop", mode_str)) {
        if (log_file) |f| {
            f.close(io);
        }
        log_file = null;
    } else if (std.ascii.eqlIgnoreCase("append", mode_str)) {
        if (log_file) |f| {
            f.close(io);
        }
        log_file = try std.Io.Dir.cwd().createFile(io, file_path, .{
            .truncate = false,
        });
    } else if (std.ascii.eqlIgnoreCase("replace", mode_str)) {
        if (log_file) |f| {
            f.close(io);
        }
        log_file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    } else {
        return error.InvalidSaveOutputMode;
    }
}

fn clear(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    var stdout = std.Io.File.stdout().writer(io, &.{});
    try stdout.interface.writeAll("\x1bc");
}

fn exit(_: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}
