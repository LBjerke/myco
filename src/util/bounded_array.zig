const std = @import("std");

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn init(len: usize) !Self {
            if (len > capacity) return error.Overflow;
            return Self{ .len = len };
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn get(self: *Self, index: usize) T {
            return self.buffer[index];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}
