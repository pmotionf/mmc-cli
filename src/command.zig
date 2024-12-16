//! This module defines the necessary types and functions to declare, queue,
//! and execute commands. Furthermore, it includes the implementations of a few
//! general purpose commands that facilitate easier use of the MMC CLI utility.

const std = @import("std");
const chrono = @import("chrono");

const v = @import("version");

// Command modules.
const mcl = @import("command/mcl.zig");
const return_demo2 = @import("command/return_demo2.zig");

const Config = @import("Config.zig");
const CircularBuffer = @import("custom_ds.zig").CircularBuffer;

// Global registry of all commands, including from other command modules.
pub var registry: std.StringArrayHashMap(Command) = undefined;

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

pub var command_queue: CircularBuffer(CommandQueue) = undefined;

var timer: ?std.time.Timer = null;
var log_file: ?std.fs.File = null;

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
    /// Waiting registers condition.
    wait_register: ?mcl.WaitRegister = null,
    /// Callback function. Passing params and context.
    execute: ?*const fn ([]CommandQueue.ParamType, *Command) anyerror!void,

    pub const Parameter = struct {
        name: []const u8,
        optional: bool = false,
        quotable: bool = true,
        resolve: bool = true,
    };
};

/// A type for storing commands and its parameters.
/// command_index: points the correct command based on registry index.
/// params: store all command parameters. Support up to 7 parameters.
///
/// NOTE:
/// 1. On client interface, command_index can be assigned by iterating over
///    registry.keys() and compare the command string. return the index.
/// 2. The parameters are u8 integer. For commands that require parameter,
///    function to convert these integers are required. (documentation required)
pub const CommandQueue = struct {
    parsed_command: CommandData,
    command_entry: *Command,

    // TODO: Accept read data. Modify command_queue
    pub fn init(self: CommandQueue) void {
        const key = registry.keys()[self.parsed_command.command_index];
        self.command_entry = registry.getPtr(key);
    }

    pub fn parseCommand(self: CommandQueue) !void {
        const command = self.command_entry;
        const params_len = command.parameters.len;
        const param_type = self.parsed_command.param_type;
        var int_idx: u8 = 0;
        var float_idx: u8 = 0;
        var params: [7]ParamType = undefined;
        const int_param = self.parsed_command.int_param;
        const float_param = self.parsed_command.float_param;
        for (0..params_len) |i| {
            const shift: u3 = @intCast(i);
            if ((param_type >> shift & 0b1) == 1) {
                const float_val =@field(lhs: anytype, comptime field_name: []const u8)
                params[i] = ParamType{ .float = float_param[float_idx] };
                float_idx += 1;
            } else {
                params[i] = ParamType{ .float = int_param[int_idx] };
                int_idx += 1;
            }
        }
        if (command.wait_register) |register| {
            self.command_entry.*.wait_register = try mcl.waitingCommand(register);
        } else {
            if (command.execute) |command_callback| {
                try command_callback(
                    params,
                    self.command_entry,
                );
            }
        }
    }

    pub const ParamType = union {
        int: u8,
        float: f32,
    };

    pub const CommandData = packed struct(u128) {
        /// Index to registry hash map
        command_index: u8,
        /// Number of parameters
        param_num: u8,
        /// Parameter types, checked with number of parameters.
        /// The first param is indicated by the last bit, and the final param is
        /// the first bit.
        param_type: u8,
        int_param: packed struct(u40) {
            int_param1: u8,
            int_param2: u8,
            int_param3: u8,
            int_param4: u8,
            int_param5: u8,
        }, // 40 bits
        float_param: packed struct(u64) {
            float_param1: f32,
            float_param2: f32,
        }, //64 bits
    };
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    if (log_file) |f| {
        var bw = std.io.bufferedWriter(f.writer());
        const writer = bw.writer();
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }

    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

pub fn init() !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    allocator = arena.allocator();

    initialized_modules = std.EnumArray(Config.Module, bool).initFill(false);
    registry = std.StringArrayHashMap(Command).init(allocator);
    variables = std.BufMap.init(allocator);
    command_queue = try CircularBuffer(CommandQueue).init(allocator, 4096);
    stop.store(false, .monotonic);
    timer = try std.time.Timer.start();

    try registry.put("HELP", .{
        .name = "HELP",
        // .parameters = &[_]Command.Parameter{
        //     .{ .name = "command", .optional = true, .resolve = false },
        // },
        .short_description = "Display detailed information about a command.",
        .long_description =
        \\Print a detailed description of a command's purpose, use, and other
        \\such aspects of consideration. A valid command name must be provided.
        \\If no command is provided, a list of all commands will be shown.
        ,
        .execute = &help,
    });
    try registry.put("VERSION", .{
        .name = "VERSION",
        .short_description = "Display the version of the MMC CLI.",
        .long_description =
        \\Print the currently running version of the MMC command line utility
        \\in Semantic Version format.
        ,
        .execute = &version,
    });
    try registry.put("LOAD_CONFIG", .{
        .name = "LOAD_CONFIG",
        // .parameters = &[_]Command.Parameter{
        //     .{ .name = "file path", .optional = true },
        // },
        .short_description = "Load CLI configuration file.",
        .long_description =
        \\Read given configuration file to dynamically load specified command
        \\modules. This configuration file must be in valid JSON format, with
        \\configuration parameters according to provided documentation.
        ,
        .execute = &loadConfig,
    });
    try registry.put("WAIT", .{
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
    try registry.put("CLEAR", .{
        .name = "CLEAR",
        .parameters = &.{},
        .short_description = "Clear visible screen output.",
        .long_description = "Clear visible screen output.",
        .execute = &clear,
    });
    // try registry.put("SET", .{
    //     .name = "SET",
    //     .parameters = &[_]Command.Parameter{
    //         .{ .name = "variable", .resolve = false },
    //         .{ .name = "value" },
    //     },
    //     .short_description = "Set a variable equal to a value.",
    //     .long_description =
    //     \\Create a variable name that resolves to the provided value in all
    //     \\future commands. Variable names are case sensitive.
    //     ,
    //     .execute = &set,
    // });
    // try registry.put("GET", .{
    //     .name = "GET",
    //     .parameters = &[_]Command.Parameter{
    //         .{ .name = "variable", .resolve = false },
    //     },
    //     .short_description = "Retrieve the value of a variable.",
    //     .long_description =
    //     \\Retrieve the resolved value of a previously created variable name.
    //     \\Variable names are case sensitive.
    //     ,
    //     .execute = &get,
    // });
    // try registry.put("VARIABLES", .{
    //     .name = "VARIABLES",
    //     .short_description = "Display all variables with their values.",
    //     .long_description =
    //     \\Print all currently set variable names along with their values.
    //     ,
    //     .execute = &printVariables,
    // });
    try registry.put("TIMER_START", .{
        .name = "TIMER_START",
        .short_description = "Start a monotonic system timer.",
        .long_description =
        \\Start monotonic system timer. Only one timer can exist per `mmc-cli`
        \\process, thus any repeated calls to this command will simply restart
        \\the timer. This command should be run once before `TIMER_READ`.
        ,
        .execute = &timerStart,
    });
    try registry.put("TIMER_READ", .{
        .name = "TIMER_READ",
        .short_description = "Read elapsed time from the system timer.",
        .long_description =
        \\Retreive the elapsed time from the last `TIMER_START` command. This
        \\timer is monotonic, and hence is unaffected by changing system time
        \\or timezone.
        ,
        .execute = &timerRead,
    });
    // try registry.put("FILE", .{
    //     .name = "FILE",
    //     .parameters = &[_]Command.Parameter{.{ .name = "path" }},
    //     .short_description = "Queue commands listed in the provided file.",
    //     .long_description =
    //     \\Add commands listed in the provided file to the front of the command
    //     \\queue. All queued commands will run first before the user is prompted
    //     \\to enter a new manual command. The queue of commands will be cleared
    //     \\if interrupted with the `Ctrl-C` hotkey. The file path provided for
    //     \\this command must be either an absolute file path or relative to the
    //     \\executable's directory. If the path contains spaces, it should be
    //     \\enclosed in double quotes (e.g. "my file path").
    //     ,
    //     .execute = &file,
    // });
    // try registry.put("SAVE_OUTPUT", .{
    //     .name = "SAVE_OUTPUT",
    //     .parameters = &[_]Command.Parameter{
    //         .{ .name = "mode" },
    //         .{ .name = "path", .optional = true },
    //     },
    //     .short_description = "Save all command output after this command.",
    //     .long_description =
    //     \\Write all program logging that occurs after this command to a file.
    //     \\The "mode" parameter can be one of three values:
    //     \\  "append" - Append output to the end of the file.
    //     \\  "replace" - Existing file contents are overwritten with output.
    //     \\  "stop" - Output after this command is no longer written to a file.
    //     \\A file path can optionally be provided to specify the output file in
    //     \\cases of "append" and "replace" modes. If a path is not provided,
    //     \\then a default logging file containing the current system date and
    //     \\time will be created in the current working directory, in the format
    //     \\"mmc-log-YYYY.MM.DD-HH.MM.SS.txt".
    //     ,
    //     .execute = &setLog,
    // });
    try registry.put("EXIT", .{
        .name = "EXIT",
        .short_description = "Exit the MMC command line utility.",
        .long_description =
        \\Gracefully terminate the PMF MMC command line utility, cleaning up
        \\resources and closing connections.
        ,
        .execute = &exit,
    });
    std.log.info("The length of registry: {}", .{registry.keys().len});
    std.log.info("The order of registry:", .{});
    const keys = registry.keys();
    const values = registry.values();
    for (0..keys.len) |idx| {
        std.log.info("{s}, #of params: {}", .{ keys[idx], values[idx].parameters.len });
    }
}

pub fn deinit() void {
    stop.store(true, .monotonic);
    defer stop.store(false, .monotonic);
    variables.deinit();
    command_queue.deinit();
    deinitModules();
    registry.deinit();
    arena.deinit();
}

// pub fn queueEmpty() bool {
//     return command_queue.items.len == 0;
// }

// pub fn queueClear() void {
//     command_queue.clearRetainingCapacity();
// }

/// Checks if the `stop` flag is set, and if so returns an error.
pub fn checkCommandInterrupt() !void {
    if (stop.load(.monotonic)) {
        defer stop.store(false, .monotonic);
        command_queue.clear();
        return error.CommandStopped;
    }
}

// pub fn enqueue(input: []const u8) !void {
//     var buffer = CommandString{
//         .buffer = undefined,
//         .len = undefined,
//     };
//     @memcpy(buffer.buffer[0..input.len], input);
//     buffer.len = input.len;
//     try command_queue.insert(0, buffer);
// }

// pub fn execute() !void {
//     const cb = command_queue.pop();
//     std.log.info("Running command: {s}\n", .{cb.buffer[0..cb.len]});
//     try parseAndRun(cb.buffer[0..cb.len]);
// }

// fn parseAndRun(input: []const u8) !void {
//     var token_iterator = std.mem.tokenizeSequence(u8, input, " ");
//     var command: *Command = undefined;
//     var command_buf: [32]u8 = undefined;
//     if (token_iterator.next()) |token| {
//         if (registry.getPtr(std.ascii.upperString(
//             &command_buf,
//             token,
//         ))) |c| {
//             command = c;
//         } else return error.InvalidCommand;
//     } else return;

//     var params: [][]const u8 = try allocator.alloc(
//         []const u8,
//         command.parameters.len,
//     );
//     defer allocator.free(params);

//     for (command.parameters, 0..) |param, i| {
//         const _token = token_iterator.peek();
//         defer _ = token_iterator.next();
//         if (_token == null) {
//             if (param.optional) {
//                 params[i] = "";
//                 continue;
//             } else return error.MissingParameter;
//         }
//         var token = _token.?;

//         // Resolve variables.
//         if (param.resolve) {
//             if (variables.get(token)) |val| {
//                 token = val;
//             }
//         }

//         if (param.quotable) {
//             if (token[0] == '"') {
//                 const start_ind: usize = token_iterator.index + 1;
//                 var len: usize = 0;
//                 while (token_iterator.next()) |tok| {
//                     try checkCommandInterrupt();
//                     if (tok[tok.len - 1] == '"') {
//                         // 2 subtracted from length to account for the two
//                         // quotation marks.
//                         len += tok.len - 2;
//                         break;
//                     }
//                     // Because the token was consumed with `.next`, the index
//                     // here will be the start index of the next token.
//                     len = token_iterator.index - start_ind;
//                 }
//                 params[i] = input[start_ind .. start_ind + len];
//             } else params[i] = token;
//         } else {
//             params[i] = token;
//         }
//     }
//     if (token_iterator.peek() != null) return error.UnexpectedParameter;
//     try command.execute(params);
// }

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

fn help(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    if (params.len > 0) {
        const command = registry.getPtr(registry.keys()[params[0]]).?;

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
    c_ptr.*.execute = null;
}

fn version(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    // TODO: Figure out better way to get version from `build.zig.zon`.
    std.log.info("CLI Version: {s}\n", .{v.version});
    c_ptr.*.execute = null;
}

fn set(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    try variables.put(params[0], params[1]);
    c_ptr.*.execute = null;
}

fn get(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    c_ptr.*.execute = null;
    if (variables.get(params[0])) |value| {
        std.log.info("Variable \"{s}\": {s}\n", .{
            params[0],
            value,
        });
    } else return error.UndefinedVariable;
}

fn printVariables(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    var variables_it = variables.iterator();
    while (variables_it.next()) |entry| {
        try checkCommandInterrupt();
        std.log.info("\t{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    c_ptr.*.execute = null;
}

fn timerStart(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    if (timer) |*t| {
        t.reset();
    } else {
        return error.SystemTimerFailure;
    }
    c_ptr.*.execute = null;
}

fn timerRead(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    if (timer) |*t| {
        var timer_value: f64 = @floatFromInt(t.read());
        timer_value = timer_value / std.time.ns_per_s;
        // Only print to microsecond precision.
        std.log.info("Timer: {d:.6}\n", .{timer_value});
    } else {
        return error.SystemTimerFailure;
    }
    c_ptr.*.execute = null;
}

fn file(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    var f = try std.fs.cwd().openFile(params[0], .{});
    var reader = f.reader();
    const current_len: usize = command_queue.items.len;
    var new_line: CommandString = .{ .buffer = undefined, .len = 0 };
    while (try reader.readUntilDelimiterOrEof(
        &new_line.buffer,
        '\n',
    )) |_line| {
        try checkCommandInterrupt();
        const line = std.mem.trimRight(u8, _line, "\r");
        new_line.len = line.len;
        std.log.info("Queueing command: {s}", .{line});
        try command_queue.insert(current_len, new_line);
    }
    c_ptr.*.execute = null;
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

fn loadConfig(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    // De-initialize any previously initialized modules.
    deinitModules();

    // Load config file.
    // TODO: Fix the temporary file_path
    const file_path = "config.json";
    const config_file = try std.fs.cwd().openFile(file_path, .{});
    var m_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const m_allocator = m_arena.allocator();
    var config = try Config.parse(m_allocator, config_file);

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
    c_ptr.*.execute = null;
}

fn wait(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    // TODO: u8 does not support big duration value
    const duration: u32 = @intCast(params[0]);
    // const duration: u32 = try std.fmt.parseInt(u32, params[0], 0);
    var wait_timer = try std.time.Timer.start();
    while (wait_timer.read() < duration * std.time.ns_per_ms) {
        try checkCommandInterrupt();
    }
    c_ptr.*.execute = null;
}

fn setLog(params: []CommandQueue.ParamType, c_ptr: *Command) !void {
    const mode_str = params[0];
    const path = params[1];

    var buf: [512]u8 = undefined;
    const file_path = if (path.len > 0) path else p: {
        var timestamp: u64 = @intCast(std.time.timestamp());
        timestamp += std.time.s_per_hour * 9;
        const days_since_epoch: i32 = @intCast(timestamp / std.time.s_per_day);
        const ymd =
            chrono.date.YearMonthDay.fromDaysSinceUnixEpoch(days_since_epoch);
        const time_day: u32 = @intCast(timestamp % std.time.s_per_day);
        const time = try chrono.Time.fromNumSecondsFromMidnight(time_day, 0);

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
            f.close();
        }
        log_file = null;
    } else if (std.ascii.eqlIgnoreCase("append", mode_str)) {
        if (log_file) |f| {
            f.close();
        }

        log_file = try std.fs.cwd().createFile(file_path, .{
            .truncate = false,
        });
    } else if (std.ascii.eqlIgnoreCase("replace", mode_str)) {
        if (log_file) |f| {
            f.close();
        }
        log_file = try std.fs.cwd().createFile(file_path, .{});
    } else {
        return error.InvalidSaveOutputMode;
    }
    c_ptr.*.execute = null;
}

fn clear(_: []CommandQueue.ParamType, c_ptr: *Command) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\x1bc");
    c_ptr.*.execute = null;
}

fn exit(_: []CommandQueue.ParamType, _: *Command) !void {
    std.process.exit(1);
}

// TODO: Remove temporary function/variables
pub fn _enqueue(str: []const u8) CommandQueue {
    var tokenizer = std.mem.tokenizeSequence(u8, str, " ");
    var result: CommandQueue = undefined;
    // get command
    if (tokenizer.next()) |token| {
        const command_str: [32]u8 = undefined;
        // get command index
        if (registry.getIndex(
            std.ascii.upperString(command_str, token),
        )) |key_idx| {
            result.parsed_command.command_index = @intCast(key_idx);
        }
    }
    // while (tokenizer.next()) |token| {}
}
