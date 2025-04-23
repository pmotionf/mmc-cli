//! This module implements the commands necessary to operate the Return
//! component of the PMF Demo 2 machine.

const std = @import("std");
const command = @import("../command.zig");
const network = @import("network");
const Command = command.Command;

pub const Config = struct {};

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

var clients_lock: std.Thread.RwLock = .{};
// All commands will be broadcasted to every client.
var clients: std.ArrayList(Client) = undefined;

var server: network.Socket = undefined;
var server_thread: std.Thread = undefined;

// Flag to stop server connection thread. Use `command.stop` for commands.
var server_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn acceptClients() !void {
    try server.listen();
    while (!server_stop.load(.monotonic)) {
        var new_connection: network.Socket = server.accept() catch |e| {
            std.log.err(
                "Accepting return system connection failed: {s}",
                .{@errorName(e)},
            );
            continue;
        };
        clients_lock.lock();
        try clients.append(.{ .conn = new_connection });
        clients_lock.unlock();
        std.log.info(
            "Client connected from {}",
            .{try new_connection.getRemoteEndPoint()},
        );
    }
}

const Client = struct {
    conn: network.Socket,
};

pub fn init(_: Config) !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    allocator = arena.allocator();
    server_stop.store(false, .monotonic);
    clients_lock.lock();
    clients = std.ArrayList(Client).init(allocator);
    clients_lock.unlock();
    try network.init();

    server = try network.Socket.create(.ipv4, .tcp);
    server.bind(.{
        .address = try network.Address.parse("127.0.0.1"),
        .port = 9001,
    }) catch |e| {
        server.close();
        server = undefined;
        return e;
    };
    server_thread = std.Thread.spawn(.{}, acceptClients, .{}) catch |e| {
        server.close();
        server = undefined;
        return e;
    };
    errdefer {
        server_stop.store(true, .monotonic);
        server.close();
        server_thread.join();
        server_stop.store(false, .monotonic);
    }

    try command.registry.put(.{
        .name = "HOME_RETURN_SYSTEM",
        .short_description = "Home the return system.",
        .long_description =
        \\Home the return system. This homing process involves movement of the
        \\start and end axes, and thus there should be no sliders positioned in
        \\such a way that could inhibit this movement. This homing process must
        \\occur at least once before other return system commands are run.
        ,
        .execute = &home,
    });
    try command.registry.put(.{
        .name = "RAISE_START_AXIS",
        .short_description = "Raise start axis to upper motion system.",
        .long_description =
        \\Raise the start axis to the motion system. This command should not be
        \\run if the return system's belt is currently moving with an attached
        \\slider.
        ,
        .execute = &raiseStartAxis,
    });
    try command.registry.put(.{
        .name = "LOWER_START_AXIS",
        .short_description = "Lower start axis to return system.",
        .long_description =
        \\Lower the start axis to the return system. This command should not be
        \\run if a slider is positioned between the start axis and the next
        \\axis.
        ,
        .execute = &lowerStartAxis,
    });
    try command.registry.put(.{
        .name = "RAISE_END_AXIS",
        .short_description = "Raise end axis to upper motion system.",
        .long_description =
        \\Raise the end axis to the motion system. This command should not be
        \\run if the return system's belt is currently moving with an attached
        \\slider.
        ,
        .execute = &raiseEndAxis,
    });
    try command.registry.put(.{
        .name = "LOWER_END_AXIS",
        .short_description = "Lower end axis to return system.",
        .long_description =
        \\Lower the end axis to the return system. This command should not be
        \\run if a slider is positioned between the end axis and the previous
        \\axis.
        ,
        .execute = &lowerEndAxis,
    });
    try command.registry.put(.{
        .name = "BELT_MOVE_START",
        .short_description = "Move the return system belt to the start axis.",
        .long_description =
        \\Move the return system belt to the start axis. This command should
        \\not be used if the belt has an attached slider while the start axis
        \\is not lowered.
        ,
        .execute = &beltMoveStart,
    });
    try command.registry.put(.{
        .name = "BELT_MOVE_END",
        .short_description = "Move the return system belt to the end axis.",
        .long_description =
        \\Move the return system belt to the end axis. This command should
        \\not be used if the belt has an attached slider while the end axis
        \\is not lowered.
        ,
        .execute = &beltMoveEnd,
    });
}

pub fn deinit() void {
    server_stop.store(true, .monotonic);
    server.close();
    server_thread.join();
    server_stop.store(false, .monotonic);

    network.deinit();
    clients_lock.lock();
    clients.deinit();
    clients_lock.unlock();
    arena.deinit();
}

fn home(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("101");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2010", buffer[0..4]))
                        return error.HomeReturnSystemError;
                    if (std.mem.eql(u8, "2011", buffer[0..4])) break;
                }
            }
            try client.conn.writer().writeAll("104");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2040", buffer[0..4]))
                        return error.RaiseStartAxisError;
                    if (std.mem.eql(u8, "2041", buffer[0..4])) break;
                }
            }
            try client.conn.writer().writeAll("106");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2060", buffer[0..4]))
                        return error.RaiseEndAxisError;
                    if (std.mem.eql(u8, "2061", buffer[0..4])) break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn raiseStartAxis(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("104");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2040", buffer[0..4]))
                        return error.RaiseStartAxisError;
                    if (std.mem.eql(u8, "2041", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn lowerStartAxis(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("105");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2050", buffer[0..4]))
                        return error.LowerStartAxisError;
                    if (std.mem.eql(u8, "2051", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn raiseEndAxis(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("106");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2060", buffer[0..4]))
                        return error.RaiseEndAxisError;
                    if (std.mem.eql(u8, "2061", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn lowerEndAxis(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("107");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2070", buffer[0..4]))
                        return error.LowerEndAxisError;
                    if (std.mem.eql(u8, "2071", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn beltMoveStart(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("102");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2020", buffer[0..4]))
                        return error.LowerEndAxisError;
                    if (std.mem.eql(u8, "2021", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}

fn beltMoveEnd(_: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt();
            try client.conn.writer().writeAll("103");
            while (true) {
                try command.checkCommandInterrupt();
                if (try client.conn.peek(&buffer) == 4) {
                    // Clear the receive stream.
                    defer _ = client.conn.receive(&buffer) catch {
                        unreachable;
                    };
                    if (std.mem.eql(u8, "2030", buffer[0..4]))
                        return error.LowerEndAxisError;
                    if (std.mem.eql(u8, "2031", buffer[0..4]))
                        break;
                }
            }
        }
    } else return error.ReturnSystemDisconnected;
}
