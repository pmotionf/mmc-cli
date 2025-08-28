const Network = @This();

// TODO: Ditch the network library. Utilize std.posix.poll to check socket status.
const std = @import("std");
const builtin = @import("builtin");
const command = @import("../../command.zig");
const client = @import("../mmc_client.zig");

// NOTE: Endpoint is saved in `Network` since the endpoint can be given during
//       the program initialization. This allows the `CONNECT` command to run
//       without any parameters, as it just execute with the saved endpoint.
/// Endpoint can be provided in two ways: reading configuration file and
/// provided by the user through Endpoint.modify.
endpoint: Endpoint,
/// Socket will be null if the connection has been closed from client (here).
socket: ?Socket,
reader_buf: []u8,
writer_buf: []u8,

pub const Endpoint = struct {
    name: []u8,
    port: u16,

    fn init(
        allocator: std.mem.Allocator,
        name: []u8,
        port: u16,
    ) std.mem.Allocator.Error!Endpoint {
        var result: Endpoint = undefined;
        result.name = try allocator.dupe(u8, name);
        result.port = port;
        return result;
    }

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.port = 0;
    }

    fn modify(
        self: *Endpoint,
        allocator: std.mem.Allocator,
        endpoint: Endpoint,
    ) std.mem.Allocator.Error!void {
        allocator.free(self.name);
        self.name = try allocator.dupe(u8, endpoint.name);
        self.port = endpoint.port;
    }
};

pub const Socket = struct {
    stream: std.net.Stream,
    reader: std.net.Stream.Reader,
    writer: std.net.Stream.Writer,

    pub fn init(
        stream: std.net.Stream,
        reader_buf: []u8,
        writer_buf: []u8,
    ) Socket {
        var result: Socket = undefined;
        result.stream = stream;
        result.reader = stream.reader(reader_buf);
        result.writer = stream.writer(writer_buf);
        return result;
    }
};
/// Initialize the endpoint for network connection
pub fn init(
    allocator: std.mem.Allocator,
    name: []u8,
    port: u16,
) (std.mem.Allocator.Error)!Network {
    var result: Network = undefined;
    result.endpoint = try .init(allocator, name, port);
    result.reader_buf = try allocator.alloc(u8, 16_384);
    result.writer_buf = try allocator.alloc(u8, 4096);
    result.socket = null;
    return result;
}

/// Clear the memory allocated for Network
pub fn deinit(self: *Network, allocator: std.mem.Allocator) void {
    self.close() catch {};
    allocator.free(self.reader_buf);
    allocator.free(self.writer_buf);
    self.endpoint.deinit(allocator);
}

/// Connect the client to the server using the provided endpoint. If the provided
/// endpoint is different from the stored one, replace the endpoint. Call `deinit`
/// to close the connection and clear the endpoint. Call `close` to close the
/// connection while retaining the last connected endpoint information.
pub fn connectToHost(
    self: *Network,
    allocator: std.mem.Allocator,
    endpoint: Endpoint,
) !void {
    if (self.socket) |_| return error.ConnectionAlreadyEstablished;
    // Try to connect with the given endpoint
    const stream = try std.net.tcpConnectToHost(
        allocator,
        endpoint.name,
        endpoint.port,
    );
    self.socket = .init(stream, self.reader_buf, self.writer_buf);
    // Replace the endpoint if the new one is different to the current one
    if (!std.mem.eql(u8, self.endpoint.name, endpoint.name)) {
        try self.endpoint.modify(allocator, endpoint);
    }
}

/// Close the socket
pub fn close(self: *Network) error{ServerNotConnected}!void {
    if (self.socket) |socket| {
        defer std.log.info(
            "Disconnected from server {s}:{d}",
            .{ self.endpoint.name, self.endpoint.port },
        );
        socket.stream.close();
        self.socket = null;
    } else return error.ServerNotConnected;
}

// NOTE: This implementation is more preferable since we do not need to copy the
//       string to a different reader. However, the zig net stream implementation
//       keep reading it without knowing that the stream already ends. If we can
//       make a simple patch to zig std.net.Stream.Reader, this implementation
//       shall be used.
//
/// Wait until the socket is ready to read a message. Return the reader.
pub fn _getReader(self: *Network) !*std.Io.Reader {
    if (self.socket) |_| {
        const reader: *std.Io.Reader = self.socket.?.reader.interface();
        while (waitingToRead(self.socket.?.stream, 0)) |wait| {
            command.checkCommandInterrupt() catch |e| {
                // Wait for 0.5 seconds to remove any incoming message. This message
                // is no longer required as the process to read the message is
                // cancelled.
                _ = try waitingToRead(self.socket.?.stream, 500);
                reader.tossBuffered();
                return e;
            };
            if (!wait) break;
        } else |e| {
            try self.close();
            return e;
        }
        return reader;
    } else return error.ServerNotConnected;
}

pub fn getReader(self: *Network) !std.Io.Reader {
    if (self.socket) |_| {
        const reader: *std.Io.Reader = self.socket.?.reader.interface();
        while (waitingToRead(self.socket.?.stream, 0)) |wait| {
            command.checkCommandInterrupt() catch |e| {
                // Wait for 0.5 seconds to remove any incoming message. This message
                // is no longer required as the process to read the message is
                // cancelled.
                _ = try waitingToRead(self.socket.?.stream, 500);
                // This implementation is a little funky as the reader need to peek at
                // least once to read the whole data.
                _ = try reader.peekByte();
                reader.tossBuffered();
                return e;
            };
            if (!wait) break;
        } else |e| {
            try self.close();
            return e;
        }
        // This implementation is a little funky as the reader need to peek at
        // least once to read the whole data.
        _ = try reader.peekByte();
        return std.Io.Reader.fixed(try reader.take(reader.bufferedLen()));
    } else return error.ServerNotConnected;
}

/// Wait until the socket is ready to write a message. Return the writer.
pub fn getWriter(self: *Network) !*std.Io.Writer {
    if (self.socket) |_| {
        const writer: *std.Io.Writer = &self.socket.?.writer.interface;
        while (waitingToWrite(self.socket.?.stream, 0)) |wait| {
            try command.checkCommandInterrupt();
            if (!wait) break;
        } else |e| {
            try self.close();
            return e;
        }
        return writer;
    } else return error.ServerNotConnected;
}

/// Check if the socket is ready to read
fn waitingToRead(
    stream: std.net.Stream,
    /// Time, in milliseconds, to wait. 0 return immediately. <0 blocking.
    timeout: i32,
) (std.posix.PollError || error{ConnectionClosedByPeer})!bool {
    const revents = try poll(
        stream.handle,
        std.posix.POLL.RDNORM,
        timeout,
    );

    if (checkRevents(revents, std.posix.POLL.HUP))
        return error.ConnectionClosedByPeer;
    if (checkRevents(revents, std.posix.POLL.RDNORM))
        return false
    else
        return true;
}

/// Check if the socket is ready to write
fn waitingToWrite(
    stream: std.net.Stream,
    /// Time, in milliseconds, to wait. 0 return immediately. <0 blocking.
    timeout: i32,
) (std.posix.PollError || error{ConnectionClosedByPeer})!bool {
    const revents = try poll(
        stream.handle,
        std.posix.POLL.OUT,
        timeout,
    );
    if (checkRevents(revents, std.posix.POLL.HUP))
        return error.ConnectionClosedByPeer;

    if (checkRevents(revents, std.posix.POLL.OUT))
        return false
    else
        return true;
}

fn checkRevents(revents: i16, mask: i16) bool {
    if (revents & mask == mask) return true else return false;
}

/// Query the socket status with the given event, return the revent.
/// Note that `POLLHUP`, `POLLNVAL`, and `POLLERR` is always returned
/// without any request. This poll() always return immediately.
fn poll(
    socket: std.net.Stream.Handle,
    events: i16,
    /// Time, in milliseconds, to wait. 0 return immediately. <0 blocking.
    timeout: i32,
) std.posix.PollError!i16 {
    const fd: std.posix.pollfd = .{
        .fd = socket,
        .events = events,
        .revents = 0,
    };
    var poll_fd: [1]std.posix.pollfd = .{fd};
    // check whether the expected socket event happen
    _ = std.posix.poll(
        &poll_fd,
        timeout,
    ) catch |e| {
        return e;
    };
    return poll_fd[0].revents;
}
