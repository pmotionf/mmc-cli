//! This module implements the commands necessary to operate the MES07-FC4E
//! laser measuring device over EtherCAT.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("soem");

const command = @import("../command.zig");
const Command = command.Command;

pub const Config = struct {};

var io_map: [4096]u8 = .{0} ** 4096;

var output_bytes: u32 = 0;
var input_bytes: u32 = 0;
var expected_WKC: u16 = 0;

var soem_ctx: *c.ecx_contextt = undefined;

/// Used by main thread to signal process thread to stop.
var stop_processing = std.atomic.Value(bool).init(false);
/// Used by process thread to signal it is currently processing.
var processing = std.atomic.Value(bool).init(false);

/// Used to share last updated laser value from process thread.
var laser_value = std.atomic.Value(i32).init(0);
/// Used to signal if last value was read, so main thread can error if the
/// process thread has unexpectedly quit.
var read_laser_value = std.atomic.Value(bool).init(false);

pub fn init(gpa: std.mem.Allocator, io: std.Io, _: Config) !void {
    soem_ctx = try gpa.create(c.ecx_contextt);
    soem_ctx.* = std.mem.zeroInit(c.ecx_contextt, .{});
    errdefer deinit(gpa, io);
    // TODO: Make every module as a type. It does not make sense to use arena here because it makes deinitialize a module impossible.
    try command.registry.put(gpa, "MES07_CONNECT", .{ .executable = .{
        .name = "MES07_CONNECT",
        .parameters = &.{
            .{ .name = "adapter", .optional = true },
        },
        .short_description = "Connect to MES07 laser device.",
        .long_description =
        \\Connect to MES07 laser device. Must be called before `MES07_READ`.
        ,
        .execute = &connect,
    } });

    try command.registry.put(gpa, "MES07_READ", .{ .executable = .{
        .name = "MES07_READ",
        .parameters = &.{
            .{ .name = "variable", .optional = true, .resolve = false },
        },
        .short_description = "Read laser device measurement value.",
        .long_description =
        \\Read laser device measurement value, and print to output. Variable
        \\names are case sensitive and shall not begin with digit.
        ,
        .execute = &read,
    } });
}

test init {
    try command.init();
    try init(.{});
    defer command.deinit();
    for (command.registry.values()) |executable| {
        for (executable.parameters, 1..) |param, i| {
            if (param.rest and i != executable.parameters.len) {
                return error.FoundInvalidRestParameter;
            }
        }
    }
}

pub fn deinit(gpa: std.mem.Allocator, io: std.Io) void {
    defer gpa.destroy(soem_ctx);
    disconnect(io, gpa, &.{}) catch {};
}

fn connect(io: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    var adapter_buf: [128]u8 = .{0} ** 128;
    var adapter: []u8 = &.{};
    if (params[0].len > 127) {
        return error.InvalidAdapterName;
    } else if (params[0].len > 0) {
        adapter = adapter_buf[0..params[0].len];
        adapter_buf[params[0].len] = 0;
        @memcpy(adapter, params[0]);

        if (c.ecx_init(soem_ctx, adapter.ptr) <= 0) {
            return error.InvalidAdapterName;
        }
    } else {
        var current_opt: ?*c.ec_adaptert = null;
        const head: ?*c.ec_adaptert = c.ec_find_adapters();
        defer c.ec_free_adapters(head);
        current_opt = head;

        while (current_opt) |current| {
            try command.checkCommandInterrupt(io);
            defer current_opt = current.next;

            var name: []const u8 = &.{};
            for (current.name, 1..) |char, i| {
                if (char != 0) {
                    name = current.name[0..i];
                } else break;
            }

            if (comptime builtin.os.tag == .linux) {
                if (std.mem.eql(u8, "lo", name)) continue;
            }

            if (c.ecx_init(soem_ctx, name.ptr) > 0) break;
        } else {
            return error.NoConnectedAdaptersFound;
        }
    }

    io_map = .{0} ** 4096;

    if (c.ecx_config_init(soem_ctx) <= 0) return error.NoEtherCatSlavesFound;

    _ = c.ecx_config_map_group(soem_ctx, &io_map, 0);
    _ = c.ecx_configdc(soem_ctx);

    while (true) {
        try command.checkCommandInterrupt(io);
        if (c.ecx_readstate(soem_ctx) == c.EC_STATE_SAFE_OP) break;
    }
    output_bytes = soem_ctx.slavelist[0].Obytes;
    if ((output_bytes == 0) and (soem_ctx.slavelist[0].Obits > 0)) output_bytes = 1;
    if (output_bytes > 8) output_bytes = 8;
    input_bytes = soem_ctx.slavelist[0].Ibytes;
    if ((input_bytes == 0) and (soem_ctx.slavelist[0].Ibits > 0)) input_bytes = 1;
    if (input_bytes > 8) input_bytes = 8;

    expected_WKC = (soem_ctx.grouplist[0].outputsWKC * 2) + soem_ctx.grouplist[0].inputsWKC;

    soem_ctx.slavelist[0].state = c.EC_STATE_OPERATIONAL;

    // send one valid process data to make outputs in slaves happy
    _ = c.ecx_send_processdata(soem_ctx);
    _ = c.ecx_receive_processdata(soem_ctx, c.EC_TIMEOUTRET);
    // request OP state for all slaves
    _ = c.ecx_writestate(soem_ctx, 0);
    // wait for all slaves to reach OP state

    errdefer {
        soem_ctx.slavelist[0].state = c.EC_STATE_INIT;
        _ = c.ecx_writestate(soem_ctx, 0);
    }
    while (true) {
        try command.checkCommandInterrupt(io);
        _ = c.ecx_send_processdata(soem_ctx);
        _ = c.ecx_receive_processdata(soem_ctx, c.EC_TIMEOUTRET);
        if (c.ecx_readstate(soem_ctx) == c.EC_STATE_OPERATIONAL) break;
    }

    while (processing.load(.monotonic)) {
        stop_processing.store(true, .monotonic);
    } else {
        stop_processing.store(false, .monotonic);
    }
    read_laser_value.store(false, .monotonic);
    const process_thread = try std.Thread.spawn(.{}, process, .{io});
    process_thread.detach();
}

fn disconnect(_: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    while (processing.load(.monotonic)) {
        stop_processing.store(true, .monotonic);
    } else {
        stop_processing.store(false, .monotonic);
    }

    c.ecx_close(soem_ctx);
}

fn process(io: std.Io) void {
    defer {
        processing.store(false, .monotonic);
    }
    var wkc: i32 = 0;
    while (!stop_processing.load(.monotonic)) {
        processing.store(true, .monotonic);
        _ = c.ecx_send_processdata(soem_ctx);
        wkc = c.ecx_receive_processdata(soem_ctx, c.EC_TIMEOUTRET);
        while (wkc < expected_WKC) {
            io.sleep(.fromMicroseconds(10), .real) catch {};
            _ = c.ecx_send_processdata(soem_ctx);
            wkc = c.ecx_receive_processdata(soem_ctx, c.EC_TIMEOUTRET);
        }
        var bytes: [4]u8 align(4) = undefined;
        var discard: [4]u8 = undefined;
        for (0..input_bytes) |i| {
            if (i < 4) {
                bytes[i] = soem_ctx.slavelist[0].inputs[i];
            } else {
                discard[i - 4] = soem_ctx.slavelist[0].inputs[i];
            }
        }

        const result_fixed_ptr: *i32 = @ptrCast(&bytes);

        const reading_fixed: i32 = result_fixed_ptr.*;
        laser_value.store(reading_fixed, .monotonic);
        read_laser_value.store(false, .monotonic);
        io.sleep(.fromMicroseconds(10), .real) catch {};
    }
}

fn read(_: std.Io, _: std.mem.Allocator, params: [][]const u8) !void {
    const save_var = params[0];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;

    if (read_laser_value.load(.monotonic) or !processing.load(.monotonic)) {
        std.log.err(
            "MES07 Communication Processing Failed. Try reconnect.",
            .{},
        );
        return error.Mes07ProcessNotUpdated;
    }

    const reading_fixed = laser_value.load(.monotonic);
    read_laser_value.store(true, .monotonic);

    const abs_val: u32 = @abs(reading_fixed);
    var print_buf: [8]u8 = undefined;
    const print_str = try std.fmt.bufPrint(&print_buf, "{c}{d}.{d:0>3.0}", .{
        @as(u8, if (reading_fixed > 0) '+' else '-'),
        abs_val / 1000,
        abs_val % 1000,
    });

    std.log.info("Laser reading: {s}", .{print_str});

    if (save_var.len > 0) {
        try command.variables.put(save_var, print_str);
    }
}
