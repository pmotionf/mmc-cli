const Config = @This();

const builtin = @import("builtin");
const std = @import("std");
const config = @import("config");
const json5 = @import("json5");

const ReturnDemo2Config = if (config.return_demo2)
    @import("modules/return_demo2.zig").Config
else
    void;
const ClientCliConfig =
    if (config.mmc_client) @import("modules/mmc_client.zig").Config else void;
const Mes07Config =
    if (config.mes07) @import("modules/mes07.zig").Config else void;

parsed: json5.Parsed(Parse),

pub const Module = enum {
    return_demo2,
    mmc_client,
    mes07,
};

const ModuleConfig = union(Module) {
    return_demo2: ReturnDemo2Config,
    mmc_client: ClientCliConfig,
    mes07: Mes07Config,
};

const Parse = struct {
    modules: []ModuleConfig,
};

// pub const Standard = union {
//     name: struct {
//         driver: []const u8 = "",
//     },
//     speed: struct {
//         range: struct {
//             min: u16 = 0,
//             max: u16 = 6000,
//         },
//         unit: []const u8 = "mm/s",
//     },
//     acceleration: struct {
//         range: struct {
//             min: f32 = 0,
//             max: f32 = 24_500,
//         },
//         unit: []const u8 = "mm/s²",
//     },
//     length: struct { unit: []const u8 = "mm" },
// };

pub fn parse(allocator: std.mem.Allocator, f: std.fs.File) !Config {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var f_reader_buf: [4096]u8 = undefined;
    var f_reader = f.reader(&f_reader_buf);
    var reader: json5.Reader = .init(a, &f_reader.interface);

    const _result = try json5.parseFromTokenSource(
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
