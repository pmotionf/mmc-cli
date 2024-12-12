const std = @import("std");

/// Custom circular buffer that can hold data other than `u8` type.
pub fn CircularBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize,
        tail: usize,
        allocator: std.mem.Allocator,

        /// Initialize a new circular buffer
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const bytes = try allocator.alloc(T, capacity);
            return Self{
                .buffer = bytes,
                .head = 0,
                .tail = 0,
                .allocator = allocator,
            };
        }

        /// Release all allocated memory
        pub fn deinit(self: Self) void {
            self.allocator.free(self.buffer);
        }

        /// Write an item to the back of the buffer
        pub fn write(self: *Self, item: T) !void {
            if ((self.tail + 1) % self.buffer.len == self.head) return error.BufferFull;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
        }

        /// Read an item from the front of the buffer
        pub fn read(self: *Self) ?T {
            if (self.tail == self.head) return null;

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            return item;
        }

        /// Peek at the front item without removing it
        pub fn peek(self: *Self) ?T {
            if (self.tail == self.head) return null;
            return self.buffer[self.head];
        }

        /// Check if the buffer is empty
        pub fn isEmpty(self: Self) bool {
            return self.tail == self.head;
        }

        /// Check if the buffer is full
        pub fn isFull(self: Self) bool {
            return ((self.tail + 1) % self.buffer.len == self.head);
        }

        /// Set head and tail to zero, simulating empty circular buffer.
        ///
        /// This function does not deallocate the memory.
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }
    };
}
