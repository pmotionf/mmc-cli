const Config = @This();

const std = @import("std");
const MclConfig = @import("command/mcl.zig").Config;
const ReturnDemo2Config = @import("command/return_demo2.zig").Config;

modules: []ModuleConfig,

pub const Module = enum {
    mcl,
    return_demo2,
};

const ModuleConfig = union(Module) {
    mcl: MclConfig,
    return_demo2: ReturnDemo2Config,
};

pub fn parse(
    allocator: std.mem.Allocator,
    f: std.fs.File,
) !std.json.Parsed(Config) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f_reader = f.reader();
    var json_reader = std.json.reader(a, f_reader);

    return try std.json.parseFromTokenSource(
        Config,
        allocator,
        &json_reader,
        .{},
    );
}

pub fn modules(self: *Config) []const ModuleConfig {
    return self.parsed.value.modules;
}

pub fn deinit(self: *Config) void {
    self.parsed.deinit();
}
