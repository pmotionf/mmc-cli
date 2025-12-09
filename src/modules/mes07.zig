//! This module implements the commands necessary to operate the MES07-FC4E
//! laser measuring device over EtherCAT.

const builtin = @import("builtin");
const std = @import("std");

const c = @cImport({
    @cInclude("soem/ethercat.h");
});

const command = @import("../command.zig");
const Command = command.Command;

pub const Config = struct {};

var connection_buf: [128]u8 = .{0} ** 128;
var connection: []u8 = connection_buf[0..0];
var io_map: [4096]u8 = .{0} ** 4096;

var output_bytes: u32 = 0;
var input_bytes: u32 = 0;
var expected_WKC: u16 = 0;

/// Used by main thread to signal process thread to stop.
var stop_processing = std.atomic.Value(bool).init(false);
/// Used by process thread to signal it is currently processing.
var processing = std.atomic.Value(bool).init(false);

/// Used to share last updated laser value from process thread.
var laser_value = std.atomic.Value(i32).init(0);
/// Used to signal if last value was read, so main thread can error if the
/// process thread has unexpectedly quit.
var read_laser_value = std.atomic.Value(bool).init(false);

pub fn init(_: Config) !void {
    try command.registry.put(.{ .executable = .{
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

    try command.registry.put(.{ .executable = .{
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

pub fn deinit() void {
    if (connection.len > 0) {
        while (processing.load(.monotonic)) {
            stop_processing.store(true, .monotonic);
        } else {
            stop_processing.store(false, .monotonic);
        }

        c.ec_close();

        connection = &.{};
    }
}

fn connect(params: [][]const u8) !void {
    var adapter_buf: [128]u8 = .{0} ** 128;
    var adapter: []u8 = &.{};
    if (params[0].len > 127) {
        return error.InvalidAdapterName;
    } else if (params[0].len > 0) {
        adapter = adapter_buf[0..params[0].len];
        adapter_buf[params[0].len] = 0;
        @memcpy(adapter, params[0]);

        if (c.ec_init(adapter.ptr) <= 0) {
            return error.InvalidAdapterName;
        } else {
            connection_buf[adapter.len] = 0;
            connection = connection_buf[0..adapter.len];
            @memcpy(connection, adapter);
        }
    } else {
        var current_opt: ?*c.ec_adaptert = null;
        const head: ?*c.ec_adaptert = c.ec_find_adapters();
        defer c.ec_free_adapters(head);
        current_opt = head;

        while (current_opt) |current| {
            try command.checkCommandInterrupt();
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

            if (c.ec_init(name.ptr) > 0) {
                connection_buf[name.len] = 0;
                connection = connection_buf[0..name.len];
                @memcpy(connection, name);
                break;
            }
        } else {
            return error.NoConnectedAdaptersFound;
        }
    }

    io_map = .{0} ** 4096;

    if (c.ec_config_init(0) <= 0) return error.NoEtherCatSlavesFound;

    _ = c.ec_config_map(&io_map);
    _ = c.ec_configdc();

    while (true) {
        try command.checkCommandInterrupt();
        if (c.ec_statecheck(
            0,
            c.EC_STATE_SAFE_OP,
            c.EC_TIMEOUTSTATE,
        ) == c.EC_STATE_SAFE_OP) {
            break;
        }
    }

    output_bytes = c.ec_slave[0].Obytes;
    if ((output_bytes == 0) and (c.ec_slave[0].Obits > 0)) output_bytes = 1;
    if (output_bytes > 8) output_bytes = 8;
    input_bytes = c.ec_slave[0].Ibytes;
    if ((input_bytes == 0) and (c.ec_slave[0].Ibits > 0)) input_bytes = 1;
    if (input_bytes > 8) input_bytes = 8;

    expected_WKC = (c.ec_group[0].outputsWKC * 2) + c.ec_group[0].inputsWKC;

    c.ec_slave[0].state = c.EC_STATE_OPERATIONAL;

    // send one valid process data to make outputs in slaves happy
    _ = c.ec_send_processdata();
    _ = c.ec_receive_processdata(c.EC_TIMEOUTRET);
    // request OP state for all slaves
    _ = c.ec_writestate(0);
    // wait for all slaves to reach OP state

    errdefer {
        c.ec_slave[0].state = c.EC_STATE_INIT;
        _ = c.ec_writestate(0);
    }
    while (true) {
        try command.checkCommandInterrupt();
        _ = c.ec_send_processdata();
        _ = c.ec_receive_processdata(c.EC_TIMEOUTRET);
        if (c.ec_statecheck(
            0,
            c.EC_STATE_OPERATIONAL,
            c.EC_TIMEOUTSTATE,
        ) == c.EC_STATE_OPERATIONAL) {
            break;
        }
    }

    while (processing.load(.monotonic)) {
        stop_processing.store(true, .monotonic);
    } else {
        stop_processing.store(false, .monotonic);
    }
    read_laser_value.store(false, .monotonic);
    const process_thread = try std.Thread.spawn(.{}, process, .{});
    process_thread.detach();
}

fn disconnect(_: [][]const u8) !void {
    if (connection.len > 0) {
        while (processing.load(.monotonic)) {
            stop_processing.store(true, .monotonic);
        } else {
            stop_processing.store(false, .monotonic);
        }

        c.ec_close();

        connection = &.{};
    }
}

fn process() void {
    defer {
        processing.store(false, .monotonic);
    }
    var wkc: i32 = 0;
    while (!stop_processing.load(.monotonic)) {
        processing.store(true, .monotonic);
        _ = c.ec_send_processdata();
        wkc = c.ec_receive_processdata(c.EC_TIMEOUTRET);
        while (wkc < expected_WKC) {
            std.Thread.sleep(std.time.ns_per_us * 10);
            _ = c.ec_send_processdata();
            wkc = c.ec_receive_processdata(c.EC_TIMEOUTRET);
        }
        var bytes: [4]u8 align(4) = undefined;
        var discard: [4]u8 = undefined;
        for (0..input_bytes) |i| {
            if (i < 4) {
                bytes[i] = c.ec_slave[0].inputs[i];
            } else {
                discard[i - 4] = c.ec_slave[0].inputs[i];
            }
        }

        const result_fixed_ptr: *i32 = @ptrCast(&bytes);

        const reading_fixed: i32 = result_fixed_ptr.*;
        laser_value.store(reading_fixed, .monotonic);
        read_laser_value.store(false, .monotonic);
        std.Thread.sleep(std.time.ns_per_us * 10);
    }
}

fn read(params: [][]const u8) !void {
    const save_var = params[0];
    if (save_var.len > 0 and std.ascii.isDigit(save_var[0]))
        return error.InvalidParameter;

    if (read_laser_value.load(.monotonic) or !processing.load(.monotonic)) {
        std.log.err(
            "MES07 Communication Processing Failed. Please reconnect.",
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
