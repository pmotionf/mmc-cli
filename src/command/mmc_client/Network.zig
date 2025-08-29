const Network = @This();

// TODO: Ditch the network library. Utilize std.posix.poll to check socket status.
const std = @import("std");
const builtin = @import("builtin");
const command = @import("../../command.zig");
const client = @import("../mmc_client.zig");

const native_os = builtin.os.tag;

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
    reader: Reader,
    writer: std.net.Stream.Writer,

    pub fn init(
        stream: std.net.Stream,
        reader_buf: []u8,
        writer_buf: []u8,
    ) Socket {
        var result: Socket = undefined;
        result.stream = stream;
        result.reader = Reader.init(stream, reader_buf);
        result.writer = stream.writer(writer_buf);
        return result;
    }

    /// Check if the socket is ready to read
    pub fn readyToRead(
        socket: *Socket,
        /// Time, in milliseconds, to wait. 0 return immediately. <0 blocking.
        timeout: i32,
    ) (std.posix.PollError || error{ConnectionClosedByPeer})!bool {
        const stream: std.net.Stream = socket.reader.net_stream;
        const revents = try poll(
            stream.handle,
            std.posix.POLL.RDNORM,
            timeout,
        );

        if (checkRevents(revents, std.posix.POLL.HUP))
            return error.ConnectionClosedByPeer;
        return checkRevents(revents, std.posix.POLL.RDNORM);
    }

    /// Check if the socket is ready to write
    pub fn readyToWrite(
        socket: *Socket,
        /// Time, in milliseconds, to wait. 0 return immediately. <0 blocking.
        timeout: i32,
    ) (std.posix.PollError || error{ConnectionClosedByPeer})!bool {
        const stream: std.net.Stream = socket.writer.getStream();
        const revents = try poll(
            stream.handle,
            std.posix.POLL.OUT,
            timeout,
        );
        if (checkRevents(revents, std.posix.POLL.HUP))
            return error.ConnectionClosedByPeer;
        return checkRevents(revents, std.posix.POLL.OUT);
    }

    pub const Reader = switch (native_os) {
        .windows => struct {
            interface: std.Io.Reader,
            net_stream: std.net.Stream,
            error_state: ?Error,

            pub const Error = ReadError;

            pub fn init(net_stream: std.net.Stream, buffer: []u8) Reader {
                return .{
                    .interface = .{
                        .vtable = &.{
                            .stream = stream,
                            .readVec = readVec,
                        },
                        .buffer = buffer,
                        .seek = 0,
                        .end = 0,
                    },
                    .net_stream = net_stream,
                    .error_state = null,
                };
            }

            fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const dest = limit.slice(try io_w.writableSliceGreedy(1));
                var bufs: [1][]u8 = .{dest};
                const n = try readVec(io_r, &bufs);
                io_w.advance(n);
                return n;
            }

            fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
                const max_buffers_len = 8;
                const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
                // Check if the socket is ready to read.
                const socket: *Socket = @alignCast(
                    @fieldParentPtr("reader", r),
                );
                if (!(socket.readyToRead(0) catch return error.ReadFailed) and
                    io_r.bufferedLen() == 0)
                    return error.EndOfStream;
                var iovecs: [max_buffers_len]std.os.windows.ws2_32.WSABUF = undefined;
                const bufs_n, const data_size = try io_r.writableVectorWsa(&iovecs, data);
                const bufs = iovecs[0..bufs_n];
                std.debug.assert(bufs[0].len != 0);
                const n = streamBufs(r, bufs) catch |err| {
                    r.error_state = err;
                    return error.ReadFailed;
                };
                if (n == 0) return error.EndOfStream;
                if (n > data_size) {
                    io_r.seek = 0;
                    io_r.end = n - data_size;
                    return data_size;
                }
                return n;
            }

            fn handleRecvError(winsock_error: std.os.windows.ws2_32.WinsockError) Error!void {
                switch (winsock_error) {
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEFAULT => unreachable, // a pointer is not completely contained in user address space.
                    .WSAEINPROGRESS, .WSAEINTR => unreachable, // deprecated and removed in WSA 2.2
                    .WSAEINVAL => return error.SocketNotBound,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENETRESET => return error.ConnectionResetByPeer,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    .WSANOTINITIALISED => unreachable, // WSAStartup must be called before this function
                    .WSA_IO_PENDING => unreachable,
                    .WSA_OPERATION_ABORTED => unreachable, // not using overlapped I/O
                    else => |err| return std.os.windows.unexpectedWSAError(err),
                }
            }

            fn streamBufs(r: *Reader, bufs: []std.os.windows.ws2_32.WSABUF) Error!u32 {
                var flags: u32 = 0;
                var overlapped: std.os.windows.OVERLAPPED = std.mem.zeroes(std.os.windows.OVERLAPPED);

                var n: u32 = undefined;
                if (std.os.windows.ws2_32.WSARecv(
                    r.net_stream.handle,
                    bufs.ptr,
                    @intCast(bufs.len),
                    &n,
                    &flags,
                    &overlapped,
                    null,
                ) == std.os.windows.ws2_32.SOCKET_ERROR) switch (std.os.windows.ws2_32.WSAGetLastError()) {
                    .WSA_IO_PENDING => {
                        var result_flags: u32 = undefined;
                        if (std.os.windows.ws2_32.WSAGetOverlappedResult(
                            r.net_stream.handle,
                            &overlapped,
                            &n,
                            std.os.windows.TRUE,
                            &result_flags,
                        ) == std.os.windows.FALSE) try handleRecvError(std.os.windows.ws2_32.WSAGetLastError());
                    },
                    else => |winsock_error| try handleRecvError(winsock_error),
                };

                return n;
            }
        },
        else => struct {
            interface: std.Io.Reader,
            net_stream: std.net.Stream,
            error_state: ?Error,

            pub const Error = ReadError;

            pub fn init(net_stream: std.net.Stream, buffer: []u8) Reader {
                return .{
                    .interface = .{
                        .vtable = &.{
                            .stream = stream,
                            .readVec = readVec,
                        },
                        .buffer = buffer,
                        .seek = 0,
                        .end = 0,
                    },
                    .net_stream = net_stream,
                    .error_state = null,
                    // .file_reader = .{
                    //     .interface = initInterface(buffer),
                    //     .file = .{ .handle = net_stream.handle },
                    //     .mode = .streaming,
                    //     .seek_err = error.Unseekable,
                    //     .size_err = error.Streaming,
                    // },
                };
            }

            /// Number of slices to store on the stack, when trying to send as many byte
            /// vectors through the underlying read calls as possible.
            const max_buffers_len = 16;

            fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const dest = limit.slice(try io_w.writableSliceGreedy(1));
                var bufs: [1][]u8 = .{dest};
                const n = try readVec(io_r, &bufs);
                io_w.advance(n);
                return n;
            }

            /// Modified readVec to read when the socket is ready to read.
            fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
                const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
                // Check if the socket is ready to read.
                const socket: *Socket = @alignCast(
                    @fieldParentPtr("reader", r),
                );
                if (!(socket.readyToRead(0) catch return error.ReadFailed) and
                    io_r.bufferedLen() == 0)
                    return error.EndOfStream;
                var iovecs_buffer: [max_buffers_len]std.posix.iovec = undefined;
                const dest_n, const data_size = try io_r.writableVectorPosix(&iovecs_buffer, data);
                const dest = iovecs_buffer[0..dest_n];
                std.debug.assert(dest[0].len > 0);
                const n = std.posix.readv(r.net_stream.handle, dest) catch |err| {
                    r.error_state = err;
                    return error.ReadFailed;
                };
                if (n == 0) return error.EndOfStream;
                if (n > data_size) {
                    io_r.seek = 0;
                    io_r.end = n - data_size;
                    return data_size;
                }
                return n;
            }
        },
    };

    pub const ReadError = std.posix.ReadError || error{
        SocketNotBound,
        MessageTooBig,
        NetworkSubsystemFailed,
        ConnectionResetByPeer,
        SocketNotConnected,
    };

    fn checkRevents(revents: i16, mask: i16) bool {
        if (revents & mask == mask) return true else return false;
    }

    /// Query the socket status with the given event, return the revent.
    /// Note that `POLLHUP`, `POLLNVAL`, and `POLLERR` is always returned
    /// without any request.
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
};

/// Initialize the endpoint for network connection
pub fn init(
    allocator: std.mem.Allocator,
    name: []u8,
    port: u16,
) (std.mem.Allocator.Error)!Network {
    var result: Network = undefined;
    result.endpoint = try .init(allocator, name, port);
    result.reader_buf = try allocator.alloc(u8, 4096);
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
        const stream: std.net.Stream = socket.reader.net_stream;
        stream.close();
        self.socket = null;
    } else return error.ServerNotConnected;
}

/// Wait until the socket is ready to read a message. Return the reader.
pub fn getReader(self: *Network) !*std.Io.Reader {
    if (self.socket) |_| {
        const reader = &self.socket.?.reader.interface;
        while (self.socket.?.readyToRead(0)) |ready| {
            command.checkCommandInterrupt() catch |e| {
                // Wait for 0.5 seconds to remove any incoming message. This message
                // is no longer required as the process to read the message is
                // cancelled.
                const arrived = try self.socket.?.readyToRead(
                    500,
                );
                if (arrived) {
                    _ = try reader.peekByte();
                    reader.tossBuffered();
                }
                return e;
            };
            if (ready) break;
        } else |e| {
            try self.close();
            return e;
        }
        return reader;
    } else return error.ServerNotConnected;
}

/// Wait until the socket is ready to write a message. Return the writer.
pub fn getWriter(self: *Network) !*std.Io.Writer {
    if (self.socket) |_| {
        const writer: *std.Io.Writer = &self.socket.?.writer.interface;
        while (self.socket.?.readyToWrite(0)) |ready| {
            try command.checkCommandInterrupt();
            if (ready) break;
        } else |e| {
            try self.close();
            return e;
        }
        return writer;
    } else return error.ServerNotConnected;
}
