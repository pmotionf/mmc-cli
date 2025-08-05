const Config = @This();

const builtin = @import("builtin");
const std = @import("std");
const config = @import("config");

const MclConfig = if (config.mcl) @import("command/mcl.zig").Config else void;
const ReturnDemo2Config = if (config.return_demo2)
    @import("command/return_demo2.zig").Config
else
    void;
const ClientCliConfig =
    if (config.mmc_client) @import("command/client_cli.zig").Config else void;
const Mes07Config =
    if (config.mes07) @import("command/mes07.zig").Config else void;

parsed: std.json.Parsed(Parse),

pub const Module = enum {
    mcl,
    return_demo2,
    client_cli,
    mes07,
};

const ModuleConfig = union(Module) {
    mcl: MclConfig,
    return_demo2: ReturnDemo2Config,
    client_cli: ClientCliConfig,
    mes07: Mes07Config,
};

const Parse = struct {
    modules: []ModuleConfig,
};

pub fn parse(allocator: std.mem.Allocator, f: std.fs.File) !Config {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f_reader_buf: [4096]u8 = undefined;
    var f_reader = f.reader(&f_reader_buf);
    var reader: std.json.Reader = .init(a, &f_reader.interface);

    const _result = try std.json.parseFromTokenSource(
        Parse,
        allocator,
        &reader,
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
