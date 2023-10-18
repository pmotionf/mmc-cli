const Config = @This();

const std = @import("std");

pub const McsConnection = enum(u8) {
    @"CC-Link Ver.2" = 0,
};

pub const McsAxis = struct {
    location: f32,
};

pub const McsDriver = struct {
    axis_1: ?McsAxis,
    axis_2: ?McsAxis,
    axis_3: ?McsAxis,
};

allocator: std.mem.Allocator = undefined,
mcs_connection: McsConnection = .@"CC-Link Ver.2",
mcs_poll_rate: u32 = 100_000,
modules: [][]const u8,
drivers: []McsDriver,

const Parse = struct {
    mcs_connection: McsConnection = .@"CC-Link Ver.2",
    mcs_poll_rate: u32 = 100_000,
    modules: [][]const u8,
    drivers: []McsDriver,
};

pub fn parse(allocator: std.mem.Allocator, f: std.fs.File) !Config {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var a = arena.allocator();
    var f_reader = f.reader();
    var json_reader = std.json.reader(a, f_reader);

    const _result = try std.json.parseFromTokenSourceLeaky(
        Parse,
        a,
        &json_reader,
        .{},
    );

    var new_modules: [][]const u8 = undefined;
    if (_result.modules.len > 0) {
        new_modules = try allocator.alloc([]const u8, _result.modules.len);
        for (_result.modules, 0..) |module, i| {
            if (module.len > 0) {
                var new_module = try allocator.alloc(u8, module.len);
                @memcpy(new_module, module);
                new_modules[i] = new_module;
            } else {
                new_modules[i] = "";
            }
        }
    } else {
        new_modules = &[_][]const u8{};
    }

    var new_drivers: []McsDriver = undefined;
    if (_result.drivers.len > 0) {
        new_drivers = try allocator.alloc(McsDriver, _result.drivers.len);
        @memcpy(new_drivers, _result.drivers);
    } else {
        new_drivers = &[_]McsDriver{};
    }

    const result = Config{
        .allocator = allocator,
        .mcs_connection = _result.mcs_connection,
        .mcs_poll_rate = _result.mcs_poll_rate,
        .modules = new_modules,
        .drivers = new_drivers,
    };
    return result;
}

pub fn deinit(self: *Config) void {
    if (self.modules.len > 0) {
        for (self.modules) |module| {
            if (module.len > 0) self.allocator.free(module);
        }
        self.allocator.free(self.modules);
        self.modules = undefined;
    }
    if (self.drivers.len > 0) self.allocator.free(self.drivers);
    self.drivers = undefined;
}
