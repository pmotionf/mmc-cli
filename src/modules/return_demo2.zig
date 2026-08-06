//! This module implements the commands necessary to operate the Return
//! component of the PMF Demo 2 machine.

const std = @import("std");
const command = @import("../command.zig");
const network = @import("network");
const Command = command.Command;

pub const Config = struct {};

var clients_lock: std.Io.RwLock = .init;
// All commands will be broadcasted to every client.
var clients: std.ArrayList(Client) = undefined;

var server: network.Socket = undefined;
var server_thread: std.Thread = undefined;

// Flag to stop server connection thread. Use `command.stop` for commands.
var server_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn acceptClients(io: std.Io) !void {
    try server.listen();
    while (!server_stop.load(.monotonic)) {
        var new_connection: network.Socket = server.accept() catch |e| {
            std.log.err(
                "Accepting return system connection failed: {s}",
                .{@errorName(e)},
            );
            continue;
        };
        clients_lock.lock(io);
        try clients.append(.{ .conn = new_connection });
        clients_lock.unlock(io);
        std.log.info(
            "Client connected from {}",
            .{try new_connection.getRemoteEndPoint()},
        );
    }
}

const Client = struct {
    conn: network.Socket,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, _: Config) !void {
    server_stop.store(false, .monotonic);
    clients_lock.lock(io);
    clients = std.ArrayList(Client).init(gpa);
    clients_lock.unlock(io);
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

    try command.registry.put(gpa, "HOME_RETURN_SYSTEM", .{
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
    try command.registry.put(gpa, "RAISE_START_AXIS", .{
        .name = "RAISE_START_AXIS",
        .short_description = "Raise start Axis to upper motion system.",
        .long_description =
        \\Raise the start Axis to the motion system. This command should not be
        \\run if the return system's belt is currently moving with an attached
        \\slider.
        ,
        .execute = &raiseStartAxis,
    });
    try command.registry.put(gpa, "LOWER_START_AXIS", .{
        .name = "LOWER_START_AXIS",
        .short_description = "Lower start Axis to return system.",
        .long_description =
        \\Lower the start Axis to the return system. This command should not be
        \\run if a slider is positioned between the start Axis and the next
        \\Axis.
        ,
        .execute = &lowerStartAxis,
    });
    try command.registry.put(gpa, "RAISE_END_AXIS", .{
        .name = "RAISE_END_AXIS",
        .short_description = "Raise end Axis to upper motion system.",
        .long_description =
        \\Raise the end Axis to the motion system. This command should not be
        \\run if the return system's belt is currently moving with an attached
        \\slider.
        ,
        .execute = &raiseEndAxis,
    });
    try command.registry.put(gpa, "LOWER_END_AXIS", .{
        .name = "LOWER_END_AXIS",
        .short_description = "Lower end Axis to return system.",
        .long_description =
        \\Lower the end Axis to the return system. This command should not be
        \\run if a slider is positioned between the end Axis and the previous
        \\Axis.
        ,
        .execute = &lowerEndAxis,
    });
    try command.registry.put(gpa, "BELT_MOVE_START", .{
        .name = "BELT_MOVE_START",
        .short_description = "Move the return system belt to the start Axis.",
        .long_description =
        \\Move the return system belt to the start Axis. This command should
        \\not be used if the belt has an attached slider while the start Axis
        \\is not lowered.
        ,
        .execute = &beltMoveStart,
    });
    try command.registry.put(gpa, "BELT_MOVE_END", .{
        .name = "BELT_MOVE_END",
        .short_description = "Move the return system belt to the end Axis.",
        .long_description =
        \\Move the return system belt to the end Axis. This command should
        \\not be used if the belt has an attached slider while the end Axis
        \\is not lowered.
        ,
        .execute = &beltMoveEnd,
    });
}

pub fn deinit(gpa: std.mem.Allocator, io: std.Io) void {
    server_stop.store(true, .monotonic);
    server.close();
    server_thread.join();
    server_stop.store(false, .monotonic);

    network.deinit();
    clients_lock.lock(io);
    clients.deinit(gpa);
    clients_lock.unlock(io);
}

fn home(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("101");
            while (true) {
                try command.checkCommandInterrupt(io);
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
                try command.checkCommandInterrupt(io);
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
                try command.checkCommandInterrupt(io);
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

fn raiseStartAxis(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("104");
            while (true) {
                try command.checkCommandInterrupt(io);
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

fn lowerStartAxis(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("105");
            while (true) {
                try command.checkCommandInterrupt(io);
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

fn raiseEndAxis(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("106");
            while (true) {
                try command.checkCommandInterrupt(io);
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

fn lowerEndAxis(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("107");
            while (true) {
                try command.checkCommandInterrupt(io);
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

fn beltMoveStart(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("102");
            while (true) {
                try command.checkCommandInterrupt(io);
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

fn beltMoveEnd(io: std.Io, _: std.mem.Allocator, _: [][]const u8) !void {
    clients_lock.lockShared();
    defer clients_lock.unlockShared();
    if (clients.items.len > 0) {
        var buffer: [8]u8 = undefined;
        for (clients.items) |client| {
            try command.checkCommandInterrupt(io);
            try client.conn.writer().writeAll("103");
            while (true) {
                try command.checkCommandInterrupt(io);
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

test {
    std.testing.refAllDecls(@This());
}
