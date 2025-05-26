//! This module defines the necessary types and functions to declare, queue,
//! and execute commands. Furthermore, it includes the implementations of a few
//! general purpose commands that facilitate easier use of the MMC CLI utility.

const builtin = @import("builtin");
const std = @import("std");
const chrono = @import("chrono");

const main = @import("main.zig");
const build = @import("build.zig.zon");

// Command modules.
const mcl = @import("command/mcl.zig");
const return_demo2 = @import("command/return_demo2.zig");
const client_cli = @import("command/client_cli.zig");
const mes07 = if (builtin.os.tag == .linux)
    @import("command/mes07.zig")
else
    struct {
        pub fn init(_: anytype) !void {}
        pub fn deinit() void {}
    };

const Config = @import("Config.zig");

pub const Registry = struct {
    mapping: std.StringArrayHashMap(Command),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .mapping = std.StringArrayHashMap(Command).init(alloc),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.mapping.deinit();
    }

    pub fn values(self: *Registry) []Command {
        return self.mapping.values();
    }

    pub fn put(self: *Registry, command: Command) !void {
        try self.mapping.put(command.name, command);
    }

    pub fn getPtr(self: *Registry, key: []const u8) ?*Command {
        return self.mapping.getPtr(key);
    }

    pub fn orderedRemove(self: *Registry, key: []const u8) void {
        _ = self.mapping.orderedRemove(key);
    }
};

pub const Table = struct {
    allocator: std.mem.Allocator,

    /// Header of pointers to variable names. Each variable name is not
    /// owned by the table.
    header: [][]const u8 = &.{},
    rows: std.ArrayList([][]const u8),

    pub fn init(gpa: std.mem.Allocator) Table {
        return .{
            .allocator = gpa,
            .header = &.{},
            .rows = std.ArrayList([][]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        if (self.header.len > 0) {
            for (self.header) |*header| {
                self.allocator.free(header.*);
            }
            self.allocator.free(self.header);
        }
        self.header = &.{};
        for (self.rows.items) |row| {
            for (row) |val| {
                if (val.len > 0) {
                    self.allocator.free(val);
                }
            }
        }
        self.rows.deinit();
    }

    fn clearRows(self: *Table) void {
        for (self.rows.items) |row| {
            for (row) |val| {
                if (val.len > 0) {
                    self.allocator.free(val);
                }
            }
        }
        self.rows.clearRetainingCapacity();
    }

    pub fn setHeader(self: *Table, columns: []const []const u8) !void {
        for (columns) |col| {
            if (variables.get(col) == null) return error.InvalidColumn;
        }

        self.clearRows();

        if (self.header.len > 0) {
            self.allocator.free(self.header);
        }

        if (columns.len == 0) return;

        self.header = try self.allocator.alloc([]const u8, columns.len);
        for (self.header) |*header| {
            header.* = &.{};
        }
        errdefer {
            for (self.header) |*header| {
                if (header.len > 0) {
                    self.allocator.free(header.*);
                }
            }

            self.allocator.free(self.header);
            self.header = &.{};
        }
        for (columns, 0..) |col, i| {
            self.header[i] = try self.allocator.dupe(
                u8,
                variables.hash_map.getKey(col).?,
            );
        }
    }

    /// Add a filled row to the end of the table, looking up variable values
    /// at time of call.
    pub fn addRow(self: *Table) !void {
        const new_row = try self.rows.addOne();
        errdefer self.rows.shrinkRetainingCapacity(self.rows.items.len - 1);
        new_row.* = try self.allocator.alloc([]const u8, self.header.len);
        errdefer self.allocator.free(new_row.*);
        for (new_row.*) |*val| {
            val.* = &.{};
        }
        errdefer {
            for (new_row.*) |*val| {
                if (val.len > 0) {
                    self.allocator.free(val.*);
                }
            }
        }
        for (new_row.*, 0..) |*val, i| {
            if (variables.get(self.header[i])) |lookup_val| {
                val.* = try self.allocator.dupe(u8, lookup_val);
            }
        }
    }
};

// Global registry of all commands, including from other command modules.
pub var registry: Registry = undefined;

// Global "stop" flag to interrupt command execution. Command modules should
// not use this atomic flag directly, but instead prefer to use the
// `checkCommandInterrupt` to check the flag, throw a `CommandStopped` error if
// set, and then reset the flag.
pub var stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Global registry of all variables.
pub var variables: std.BufMap = undefined;

pub var table: Table = undefined;

// Flags to keep track of currently initialized modules, so that only
// initialized will be deinitialized.
var initialized_modules: std.EnumArray(Config.Module, bool) = undefined;

var command_queue_lock: std.Thread.RwLock = undefined;
var command_queue: std.DoublyLinkedList = undefined;

var timer: ?std.time.Timer = null;
var log_file: ?std.fs.File = null;

const CommandString = struct {
    str: []u8,
    node: std.DoublyLinkedList.Node,
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
    registry = Registry.init(allocator);
    variables = std.BufMap.init(allocator);
    table = Table.init(std.heap.smp_allocator);
    command_queue = .{ .first = null, .last = null };
    command_queue_lock = .{};
    stop.store(false, .monotonic);
    timer = try std.time.Timer.start();

    try registry.put(.{
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
    try registry.put(.{
        .name = "VERSION",
        .short_description = "Display the version of the MMC CLI.",
        .long_description =
        \\Print the currently running version of the MMC command line utility
        \\in Semantic Version format.
        ,
        .execute = &version,
    });
    try registry.put(.{
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
    try registry.put(.{
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
    try registry.put(.{
        .name = "CLEAR",
        .parameters = &.{},
        .short_description = "Clear visible screen output.",
        .long_description = "Clear visible screen output.",
        .execute = &clear,
    });
    try registry.put(.{
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
    try registry.put(.{
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
    try registry.put(.{
        .name = "VARIABLES",
        .short_description = "Display all variables with their values.",
        .long_description =
        \\Print all currently set variable names along with their values.
        ,
        .execute = &printVariables,
    });
    try registry.put(.{
        .name = "TABLE_RESET",
        .short_description = "Fully reset global table to be empty.",
        .long_description =
        \\Reset all table rows and columns to be empty. An empty table after
        \\reset cannot be saved to file, as a zero-column table is considered
        \\invalid.
        ,
        .execute = &tableReset,
    });
    try registry.put(.{
        .name = "TABLE_SET_COLUMNS",
        .parameters = &.{
            .{
                .name = "variables",
            },
        },
        .short_description = "Set variables to table columns.",
        .long_description =
        \\Set the global table's columns to represent the provided variables.
        \\The variables must already exist, and must be provided by name with
        \\each variable name separated by a comma (,).
        \\Each variable will be set to its own column, in the provided order.
        \\Each time a row is added to the table, the columns' variable values
        \\will be saved.
        ,
        .execute = &tableSetColumns,
    });
    try registry.put(.{
        .name = "TABLE_ADD_ROW",
        .short_description = "Add row of current variable values to table.",
        .long_description =
        \\
        ,
        .execute = &tableAddRow,
    });
    try registry.put(.{
        .name = "TABLE_SAVE",
        .parameters = &.{
            .{ .name = "file path" },
        },
        .short_description = "Save table to provided file path.",
        .long_description =
        \\Save table to provided file path in CSV format.
        ,
        .execute = &tableSave,
    });
    try registry.put(.{
        .name = "TIMER_START",
        .short_description = "Start a monotonic system timer.",
        .long_description =
        \\Start monotonic system timer. Only one timer can exist per `mmc-cli`
        \\process, thus any repeated calls to this command will simply restart
        \\the timer. This command should be run once before `TIMER_READ`.
        ,
        .execute = &timerStart,
    });
    try registry.put(.{
        .name = "TIMER_READ",
        .short_description = "Read elapsed time from the system timer.",
        .long_description =
        \\Retreive the elapsed time from the last `TIMER_START` command. This
        \\timer is monotonic, and hence is unaffected by changing system time
        \\or timezone.
        ,
        .execute = &timerRead,
    });
    try registry.put(.{
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
    try registry.put(.{
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
    try registry.put(.{
        .name = "EXIT",
        .short_description = "Exit the MMC command line utility.",
        .long_description =
        \\Gracefully terminate the PMF MMC command line utility, cleaning up
        \\resources and closing connections.
        ,
        .execute = &exit,
    });
}

pub fn deinit() void {
    stop.store(true, .monotonic);
    defer stop.store(false, .monotonic);
    variables.deinit();
    queueClear();
    command_queue_lock = undefined;
    deinitModules();
    registry.deinit();
    arena.deinit();
}

pub fn queueEmpty() bool {
    command_queue_lock.lockShared();
    defer command_queue_lock.unlockShared();
    return command_queue.first == null and command_queue.last == null;
}

pub fn queueClear() void {
    command_queue_lock.lock();
    defer command_queue_lock.unlock();
    while (command_queue.popFirst()) |node| {
        const command_str: *CommandString = @fieldParentPtr("node", node);
        std.heap.smp_allocator.free(command_str.str);
        std.heap.smp_allocator.destroy(command_str);
    }
}

/// Checks if the `stop` flag is set, and if so returns an error.
pub fn checkCommandInterrupt() !void {
    if (stop.load(.monotonic)) {
        defer stop.store(false, .monotonic);
        queueClear();
        return error.CommandStopped;
    }
}

pub fn enqueue(input: []const u8) !void {
    const str = try std.heap.smp_allocator.dupe(u8, input);
    errdefer std.heap.smp_allocator.free(str);
    const new_node: *CommandString =
        try std.heap.smp_allocator.create(CommandString);
    new_node.str = str;
    command_queue_lock.lock();
    defer command_queue_lock.unlock();
    command_queue.append(&new_node.node);
}

pub fn execute() !void {
    command_queue_lock.lock();
    const node_opt = command_queue.popFirst();
    command_queue_lock.unlock();
    if (node_opt) |node| {
        const command_str: *CommandString = @fieldParentPtr("node", node);
        defer {
            std.heap.smp_allocator.free(command_str.str);
            std.heap.smp_allocator.destroy(command_str);
        }
        try parseAndRun(command_str.str);
    }
}

fn parseAndRun(input: []const u8) !void {
    const trimmed = std.mem.trimLeft(u8, input, "\n\t \r");
    std.log.info("Running command: {s}\n", .{trimmed});
    if (trimmed.len == 0 or trimmed[0] == '#') {
        return;
    }
    var token_iterator = std.mem.tokenizeSequence(u8, trimmed, " ");
    var command: *Command = undefined;
    var command_buf: [256]u8 = undefined;
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
    try command.execute(params);
}

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

fn help(params: [][]const u8) !void {
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

fn version(_: [][]const u8) !void {
    // TODO: Figure out better way to get version from `build.zig.zon`.
    std.log.info("CLI Version: {s}\n", .{build.version});
}

fn set(params: [][]const u8) !void {
    try variables.put(params[0], params[1]);
}

fn get(params: [][]const u8) !void {
    if (variables.get(params[0])) |value| {
        std.log.info("Variable \"{s}\": {s}\n", .{
            params[0],
            value,
        });
    } else return error.UndefinedVariable;
}

fn printVariables(_: [][]const u8) !void {
    var variables_it = variables.iterator();
    while (variables_it.next()) |entry| {
        try checkCommandInterrupt();
        std.log.info("\t{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn tableReset(_: [][]const u8) !void {
    table.clearRows();
    // Should be impossible to fail with an empty header.
    table.setHeader(&.{}) catch unreachable;
}

fn tableSetColumns(params: [][]const u8) !void {
    const all_variables = params[0];
    var names = std.mem.splitScalar(u8, all_variables, ',');
    var names_count: usize = 0;
    var names_buf: [2048][]const u8 = undefined;
    while (names.next()) |name| {
        names_buf[names_count] = name;
        names_count += 1;
    }
    try table.setHeader(names_buf[0..names_count]);
}

fn tableAddRow(_: [][]const u8) !void {
    try table.addRow();
}

fn tableSave(params: [][]const u8) !void {
    const path = params[0];

    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    for (table.header) |col| {
        try f.writeAll(col);
        try f.writeAll(",");
    }
    try f.writeAll("\n");

    for (table.rows.items) |row| {
        for (row) |val| {
            try f.writeAll(val);
            try f.writeAll(",");
        }
        try f.writeAll("\n");
    }
}

fn timerStart(_: [][]const u8) !void {
    if (timer) |*t| {
        t.reset();
    } else {
        return error.SystemTimerFailure;
    }
}

fn timerRead(_: [][]const u8) !void {
    if (timer) |*t| {
        var timer_value: f64 = @floatFromInt(t.read());
        timer_value = timer_value / std.time.ns_per_s;
        // Only print to microsecond precision.
        std.log.info("Timer: {d:.6}\n", .{timer_value});
    } else {
        return error.SystemTimerFailure;
    }
}

fn file(params: [][]const u8) !void {
    var f = try std.fs.cwd().openFile(params[0], .{});
    defer f.close();
    var reader = f.reader();
    var buf: [std.fs.max_path_bytes + 512]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |_line| {
        try checkCommandInterrupt();
        const line = std.mem.trimLeft(
            u8,
            std.mem.trimRight(u8, _line, "\r"),
            "\n\t ",
        );
        if (line.len == 0 or line[0] == '#') continue;
        std.log.info("Queueing command: {s}", .{line});
        try enqueue(line);
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

fn loadConfig(params: [][]const u8) !void {
    // De-initialize any previously initialized modules.
    deinitModules();

    // Load config file.
    const config_file = if (params[0].len > 0)
        try std.fs.cwd().openFile(params[0], .{})
    else
        std.fs.cwd().openFile("config.json", .{}) catch exe_local: {
            var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_dir_path = std.fs.selfExeDirPath(&exe_dir_buf) catch
                break :exe_local error.FileNotFound;
            var exe_dir = std.fs.cwd().openDir(exe_dir_path, .{}) catch
                break :exe_local error.FileNotFound;
            defer exe_dir.close();
            break :exe_local exe_dir.openFile("config.json", .{});
        } catch config_local: {
            var config_dir = switch (comptime builtin.os.tag) {
                .windows => b: {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
                    const fba_alloc = fba.allocator();
                    const home_path = try std.process.getEnvVarOwned(
                        fba_alloc,
                        "USERPROFILE",
                    );

                    var home_dir = try std.fs.cwd().openDir(home_path, .{});
                    defer home_dir.close();
                    break :b try home_dir.openDir(".config", .{});
                },
                .linux => b: {
                    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
                    const fba_alloc = fba.allocator();
                    const config_path = std.process.getEnvVarOwned(
                        fba_alloc,
                        "XDG_CONFIG_HOME",
                    ) catch "";
                    if (config_path.len > 0) {
                        break :b try std.fs.cwd().openDir(config_path, .{});
                    }
                    const home_path = try std.process.getEnvVarOwned(
                        fba_alloc,
                        "HOME",
                    );
                    var home_dir = try std.fs.cwd().openDir(home_path, .{});
                    defer home_dir.close();
                    break :b try home_dir.openDir(".config", .{});
                },
                else => return error.UnsupportedOs,
            };

            break :config_local try config_dir.openFile(
                "mmc_cli_config.json",
                .{},
            );
        };
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
}

fn wait(params: [][]const u8) !void {
    const duration: u64 = try std.fmt.parseInt(u64, params[0], 0);
    var wait_timer = try std.time.Timer.start();
    while (wait_timer.read() < duration * std.time.ns_per_ms) {
        try checkCommandInterrupt();
    }
}

fn setLog(params: [][]const u8) !void {
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
}

fn clear(_: [][]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("\x1bc");
}

fn exit(_: [][]const u8) !void {
    main.exit.store(true, .monotonic);
}
