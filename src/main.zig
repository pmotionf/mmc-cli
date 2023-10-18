const builtin = @import("builtin");
const std = @import("std");
const network = @import("network");
const command = @import("command.zig");
const mcs = @import("command/mcs.zig");
const return_demo2 = @import("command/return_demo2.zig");

const Config = @import("Config.zig");

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    var line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    const result = std.mem.trimRight(u8, line, "\r");
    return result;
}

fn stopCommand(
    dwCtrlType: std.os.windows.DWORD,
) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
        command.stop.store(true, .Monotonic);
        std.io.getStdIn().sync() catch {};
    }
    return 1;
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        try std.os.windows.SetConsoleCtrlHandler(&stopCommand, true);
    }

    try command.init();
    defer command.deinit();

    // Load config file.
    var config_file = try std.fs.cwd().openFile("config.json", .{});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = arena.allocator();
    var config = try Config.parse(allocator, config_file);
    defer config.deinit();

    for (config.modules) |module_name| {
        if (std.mem.eql(u8, module_name, "mcs")) {
            try mcs.init(config);
        } else if (std.mem.eql(u8, module_name, "return_demo2")) {
            try return_demo2.init();
        }
    }
    defer {
        for (config.modules) |module_name| {
            if (std.mem.eql(u8, module_name, "mcs")) {
                mcs.deinit();
            } else if (std.mem.eql(u8, module_name, "return_demo2")) {
                return_demo2.deinit();
            }
        }
    }

    const standard_in = std.io.getStdIn();
    var buffered_reader = std.io.bufferedReader(standard_in.reader());
    var reader = buffered_reader.reader();

    command_loop: while (true) {
        std.io.getStdIn().sync() catch {};
        if (command.stop.load(.Monotonic)) {
            command.queueClear();
            command.stop.store(false, .Monotonic);
        }
        if (command.queueEmpty()) {
            var input_buffer: [1024]u8 = .{0} ** 1024;
            std.log.info("Please enter a command (HELP for info): ", .{});

            if (try nextLine(reader, &input_buffer)) |line| {
                try command.enqueue(line);
            } else continue :command_loop;
        }
        command.execute() catch |e| {
            std.log.err("{s}", .{@errorName(e)});
            command.queueClear();
            continue :command_loop;
        };
    }
}
