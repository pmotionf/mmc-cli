const std = @import("std");

/// Generic circular buffer (aka ring buffer) implementation. Buffer's length
/// is equivalent to its capacity, and is non-resizable.
pub fn CircularBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize,
        tail: usize,
        allocator: std.mem.Allocator,

        /// Initialize circular buffer capacity. Capacity is not resizable.
        pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !Self {
            const bytes = try allocator.alloc(T, num);
            return Self{
                .buffer = bytes,
                .head = 0,
                .tail = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.buffer);
        }

        /// Writes item to tail of buffer. Errors if buffer is full. Does not
        /// allocate.
        pub fn writeItem(self: *Self, item: T) !void {
            if ((self.tail + 1) % self.buffer.len == self.head)
                return error.BufferFull;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
        }

        /// Read next item from front of buffer. Advances buffer head.
        pub fn readItem(self: *Self) ?T {
            if (self.tail == self.head) return null;

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            return item;
        }

        /// Peek at next item from front of buffer. Does not advance head.
        pub fn peek(self: *Self) ?T {
            if (self.tail == self.head) return null;
            return self.buffer[self.head];
        }

        /// Discard up to first count items in buffer. Count must be less than
        /// or equal to buffer length.
        pub fn discard(self: *Self, count: usize) void {
            std.debug.assert(count <= self.buffer.len);
            const remove_count: usize = @min(count, self.items());
            self.head = (self.head + remove_count) % self.buffer.len;
        }

        /// Returns true if buffer is empty and false otherwise.
        pub fn isEmpty(self: Self) bool {
            return self.tail == self.head;
        }

        /// Returns true if buffer is full and false otherwise.
        pub fn isFull(self: Self) bool {
            return ((self.tail + 1) % self.buffer.len == self.head);
        }

        /// Discard all items in buffer. Does not free/reset capacity.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }

        /// Get the total number of items in buffer.
        pub fn items(self: Self) usize {
            if (self.tail >= self.head) {
                return self.tail - self.head;
            } else {
                return self.buffer.len - self.head + self.tail;
            }
        }
    };
}
