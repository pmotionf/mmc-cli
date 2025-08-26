const Network = @This();

// TODO: Ditch the network library. Utilize std.posix.poll to check socket status.
const std = @import("std");
pub const network = @import("network");
const command = @import("../../command.zig");
const client = @import("../mmc_client.zig");

socket: ?network.Socket,
endpoint: Endpoint,

pub const Endpoint = struct {
    ip: []u8,
    port: u16,

    fn modify(
        self: *Endpoint,
        allocator: std.mem.Allocator,
        endpoint: Endpoint,
    ) std.mem.Allocator.Error!void {
        allocator.free(self.ip);
        self.ip = try allocator.dupe(u8, endpoint.ip);
        self.port = endpoint.port;
    }
};

/// Initialize the endpoint for network connection
pub fn init(
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
) (std.mem.Allocator.Error || error{InitializationError})!Network {
    var result: Network = undefined;
    errdefer result.deinit(allocator);
    result.endpoint.ip = try allocator.dupe(u8, endpoint.ip);
    result.endpoint.port = endpoint.port;
    result.socket = null;
    try network.init();
    return result;
}

/// Clear the memory allocated for Network
pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
    self.close() catch {};
    allocator.free(self.endpoint.ip);
    self.endpoint.ip = &.{};
    self.endpoint.port = 0;
    network.deinit();
}

// TODO: The connect function should connect from the saved endpoint.
/// Connect the client to the server using. Call `deinit` to close the connection and
/// clear memory allocated for the IP. Call `close` to close the connection
/// while retaining the last connected endpoint information.
pub fn connect(
    self: *Network,
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
) !void {
    // Try to connect with the given endpoint
    const socket = try network.connectToHost(
        allocator,
        endpoint.ip,
        endpoint.port,
        .tcp,
    );
    // Replace the endpoint if the new one is different to the current one
    if (!std.mem.eql(u8, self.endpoint.ip, endpoint.ip)) {
        try self.endpoint.modify(allocator, endpoint);
    }
    self.socket = socket;
}

/// Close the socket
pub fn close(self: *Network) error{ServerNotConnected}!void {
    if (self.socket) |socket| {
        defer std.log.info(
            "Disconnected from server {s}:{d}",
            .{ self.endpoint.ip, self.endpoint.port },
        );
        socket.close();
        self.socket = null;
    } else return error.ServerNotConnected;
}

pub fn send(self: *Network, msg: []const u8) !void {
    if (self.socket) |socket| {
        // check if the socket can write without blocking
        while (self.isSocketEventOccurred(
            std.posix.POLL.OUT,
            0,
        )) |socket_status| {
            if (socket_status) break;
            try command.checkCommandInterrupt();
        } else |sock_err| {
            try self.close();
            return sock_err;
        }
        var writer = socket.writer(&.{});
        defer writer.interface.flush() catch {};
        writer.interface.writeAll(msg) catch |e| {
            try self.close();
            return e;
        };
    } else return error.ServerNotConnected;
}

/// Non-blocking receive from socket
pub fn receive(self: *Network, allocator: std.mem.Allocator) ![]const u8 {
    if (self.socket) |socket| {
        // Check if the socket can read without blocking.
        // TODO: Calculate the maximum required buffer for receiving the current
        //       api's response.
        var buf: [16_384]u8 = undefined;
        while (self.isSocketEventOccurred(
            std.posix.POLL.IN,
            0,
        )) |socket_status| {
            // This step is required for reading from socket as the socket
            // may still receive some message from server. This message is no
            // longer valuable, thus ignored in the catch.
            command.checkCommandInterrupt() catch |e| {
                if (self.isSocketEventOccurred(
                    std.posix.POLL.IN,
                    500,
                )) |_socket_status| {
                    if (_socket_status)
                        // Remove any incoming messages, if any.
                        _ = socket.receive(&buf) catch {
                            try self.close();
                        };
                    return e;
                } else |sock_err| {
                    try self.close();
                    return sock_err;
                }
            };
            if (socket_status) break;
        } else |sock_err| {
            try self.close();
            return sock_err;
        }
        const msg_size = socket.receive(&buf) catch |e| {
            try self.close();
            return e;
        };
        // msg_size value 0 means the connection is gracefully closed
        if (msg_size == 0) {
            try self.close();
            return error.ConnectionClosed;
        }
        return allocator.dupe(u8, buf[0..msg_size]);
    } else return error.ServerNotConnected;
}

// TODO: Create a variable that holds function to check if the socket is ready
// to read, write, accept connection, disconnected, error, and invalid.
/// Check whether the socket has event flag occurred. Timeout is in milliseconds
/// unit.
pub fn isSocketEventOccurred(self: *Network, event: i16, timeout: i32) !bool {
    if (self.socket) |socket| {
        const fd: std.posix.pollfd = .{
            .fd = socket.internal,
            .events = event,
            .revents = 0,
        };
        var poll_fd: [1]std.posix.pollfd = .{fd};
        // check whether the expected socket event happen
        const status = std.posix.poll(
            &poll_fd,
            timeout,
        ) catch |e| {
            try self.close();
            return e;
        };
        if (status == 0)
            return false
        else {
            // POLL.HUP: the peer gracefully close the socket
            if (poll_fd[0].revents & std.posix.POLL.HUP == std.posix.POLL.HUP)
                return error.ConnectionResetByPeer
            else if (poll_fd[0].revents & std.posix.POLL.ERR == std.posix.POLL.ERR)
                return error.ConnectionError
            else if (poll_fd[0].revents & std.posix.POLL.NVAL == std.posix.POLL.NVAL)
                return error.InvalidSocket
            else
                return true;
        }
    } else return error.ServerNotConnected;
}
