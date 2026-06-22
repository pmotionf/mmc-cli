const Config = @This();

const std = @import("std");
const MclConfig = @import("command/mcl.zig").Config;
const ReturnDemo2Config = @import("command/return_demo2.zig").Config;

parsed: std.json.Parsed(Parse),

pub const Module = enum {
    mcl,
};

const ModuleConfig = union(Module) {
    mcl: MclConfig,
};

const Parse = struct {
    modules: []ModuleConfig,
};

pub fn parse(io: std.Io, gpa: std.mem.Allocator, f: std.Io.File) !Config {
    var file_buffer: [4096]u8 = undefined;
    var file_reader = f.reader(io, &file_buffer);
    var json_reader: std.json.Reader = .init(gpa, &file_reader.interface);
    defer json_reader.deinit();
    const _result = try std.json.parseFromTokenSource(
        Parse,
        gpa,
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

test {
    std.testing.refAllDecls(@This());
}
