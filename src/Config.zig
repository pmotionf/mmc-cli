const Config = @This();

const std = @import("std");
const McsConfig = @import("command/mcs.zig").Config;
const ReturnDemo2Config = @import("command/return_demo2.zig").Config;

parsed: std.json.Parsed(Parse),

pub const Module = enum {
    mcs,
    return_demo2,
};

const ModuleConfig = union(Module) {
    mcs: McsConfig,
    return_demo2: ReturnDemo2Config,
};

const Parse = struct {
    modules: []ModuleConfig,
};

pub fn parse(allocator: std.mem.Allocator, f: std.fs.File) !Config {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = arena.allocator();
    var f_reader = f.reader();
    var json_reader = std.json.reader(a, f_reader);

    const _result = try std.json.parseFromTokenSource(
        Parse,
        allocator,
        &json_reader,
        .{},
    );

    const result = Config{
        .parsed = _result,
    };
    return result;
}

pub fn modules(self: *Config) []const ModuleConfig {
    return self.parsed.value.modules;
}

pub fn deinit(self: *Config) void {
    self.parsed.deinit();
}
