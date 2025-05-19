const std = @import("std");

pub fn CircularBuffer(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        const Index = std.math.IntFittingRange(0, size - 1);
        const Size = std.math.IntFittingRange(0, size);

        buffer: [size]T = undefined,
        head: Index = 0,
        count: Size = 0,

        pub fn getTail(self: *const Self) ?T {
            if (self.count == 0) return null;
            return self.buffer[
                (self.head + self.count - 1) % self.buffer.len
            ];
        }

        pub fn getTailIndex(self: *const Self) ?Index {
            if (self.count == 0) return null;
            return @intCast((self.head + self.count - 1) % self.buffer.len);
        }

        /// Get index of next write to buffer.
        pub fn getWriteIndex(self: *const Self) Index {
            return @intCast((self.head + self.count) % self.buffer.len);
        }

        /// Writes item to tail of buffer. Errors if buffer is full. Does not
        /// allocate.
        pub fn writeItem(self: *Self, item: T) !void {
            if (self.count == self.buffer.len)
                return error.BufferFull;

            if (@typeInfo(T) == .array) {
                @memcpy(
                    &self.buffer[(self.head + self.count) % self.buffer.len],
                    &item,
                );
            } else {
                self.buffer[(self.head + self.count) % self.buffer.len] = item;
            }
            self.count += 1;
        }

        /// Writes item to the tail of the buffer. Overwrites the oldest item
        /// if full. Does not allocate.
        pub fn writeItemOverwrite(self: *Self, item: T) void {
            if (@typeInfo(T) == .array) {
                @memcpy(
                    &self.buffer[(self.head + self.count) % self.buffer.len],
                    &item,
                );
            } else {
                self.buffer[(self.head + self.count) % self.buffer.len] = item;
            }
            if (self.count == self.buffer.len)
                self.head = @intCast((self.head + 1) % self.buffer.len)
            else
                self.count += 1;
        }

        /// Read next item from front of buffer. Advances buffer head.
        pub fn readItem(self: *Self) ?T {
            if (self.count == 0) return null;

            const item = self.buffer[self.head];
            self.head = @intCast((self.head + 1) % self.buffer.len);
            self.count -= 1;
            return item;
        }

        /// Peek at next item from front of buffer. Does not advance head.
        pub fn peek(self: *Self) ?T {
            if (self.count == 0) return null;
            return self.buffer[self.head];
        }

        /// Discard up to first count items in buffer. Count must be less than
        /// or equal to current used buffer length.
        pub fn discard(self: *Self, count: usize) void {
            std.debug.assert(count <= self.count);
            const remove_count: usize = @min(count, self.items());
            self.head =
                @intCast((self.head + remove_count) % self.buffer.len);
            self.count -= count;
        }

        /// Returns true if buffer is empty and false otherwise.
        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        /// Returns true if buffer is full and false otherwise.
        pub fn isFull(self: Self) bool {
            return self.count == self.buffer.len;
        }

        /// Discard all items in buffer. Does not free/reset capacity.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        /// Get the total number of items in buffer.
        pub fn items(self: Self) usize {
            return self.count;
        }
    };
}

/// Generic circular buffer (aka ring buffer) implementation. Buffer's length
/// is equivalent to its capacity, and is non-resizable.
pub fn CircularBufferAlloc(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        head: usize,
        count: usize,
        allocator: std.mem.Allocator,

        /// Initialize circular buffer capacity. Capacity is not resizable.
        pub fn initCapacity(allocator: std.mem.Allocator, num: usize) !Self {
            const bytes = try allocator.alloc(T, num);
            return Self{
                .buffer = bytes,
                .head = 0,
                .count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.buffer);
        }

        /// Writes item to tail of buffer. Errors if buffer is full. Does not
        /// allocate.
        pub fn writeItem(self: *Self, item: T) !void {
            if (self.count == self.buffer.len)
                return error.BufferFull;

            if (@typeInfo(T) == .array) {
                @memcpy(
                    &self.buffer[(self.head + self.count) % self.buffer.len],
                    &item,
                );
            } else {
                self.buffer[(self.head + self.count) % self.buffer.len] = item;
            }
            self.count += 1;
        }

        test writeItem {
            const text1 = "Testing from the Earth";
            const text2 = "Received by someone in the future";
            const full_text = text1 ++ "\n" ++ text2;
            var ring_buf =
                try CircularBufferAlloc([full_text.len]u8).initCapacity(
                    std.testing.allocator,
                    1,
                );

            defer ring_buf.deinit();

            // test writeItem
            try ring_buf.writeItem(full_text.*);

            var iterator =
                std.mem.tokenizeSequence(
                    u8,
                    &ring_buf.readItem().?,
                    "\n",
                );
            try std.testing.expectEqualStrings(text1, iterator.next().?);
            try std.testing.expectEqualStrings(text2, iterator.next().?);
            try std.testing.expect(ring_buf.isEmpty());
        }

        /// Writes item to the tail of the buffer. Overwrites the oldest item
        /// if full. Does not allocate.
        pub fn writeItemOverwrite(self: *Self, item: T) void {
            if (@typeInfo(T) == .array) {
                @memcpy(
                    &self.buffer[(self.head + self.count) % self.buffer.len],
                    &item,
                );
            } else {
                self.buffer[(self.head + self.count) % self.buffer.len] = item;
            }
            if (self.count == self.buffer.len)
                self.head = (self.head + 1) % self.buffer.len
            else
                self.count += 1;
        }

        test writeItemOverwrite {
            const text1 = "Testing from the Earth";
            const text2 = "Received by someone in the future";
            const full_text1 = text1 ++ "\n" ++ text2;
            const text3 = "Testing from the future";
            const text4 = "Received by someone in the Earth";
            const full_text2 = text3 ++ "\n" ++ text4;
            var ring_buf =
                try CircularBufferAlloc([full_text1.len]u8).initCapacity(
                    std.testing.allocator,
                    1,
                );

            defer ring_buf.deinit();

            ring_buf.writeItemOverwrite(full_text1.*);
            try std.testing.expect(ring_buf.isFull());
            ring_buf.writeItemOverwrite(full_text2.*);
            var iterator =
                std.mem.tokenizeSequence(
                    u8,
                    &ring_buf.readItem().?,
                    "\n",
                );
            try std.testing.expectEqualStrings(text3, iterator.next().?);
            try std.testing.expectEqualStrings(text4, iterator.next().?);
            try std.testing.expect(ring_buf.isEmpty());
        }

        /// Read next item from front of buffer. Advances buffer head.
        pub fn readItem(self: *Self) ?T {
            if (self.count == 0) return null;

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;
            return item;
        }

        /// Peek at next item from front of buffer. Does not advance head.
        pub fn peek(self: *Self) ?T {
            if (self.count == 0) return null;
            return self.buffer[self.head];
        }

        /// Discard up to first count items in buffer. Count must be less than
        /// or equal to current used buffer length.
        pub fn discard(self: *Self, count: usize) void {
            std.debug.assert(count <= self.count);
            const remove_count: usize = @min(count, self.items());
            self.head = (self.head + remove_count) % self.buffer.len;
            self.count -= count;
        }

        /// Returns true if buffer is empty and false otherwise.
        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        /// Returns true if buffer is full and false otherwise.
        pub fn isFull(self: Self) bool {
            return self.count == self.buffer.len;
        }

        /// Discard all items in buffer. Does not free/reset capacity.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }

        /// Get the total number of items in buffer.
        pub fn items(self: Self) usize {
            return self.count;
        }
    };
}
