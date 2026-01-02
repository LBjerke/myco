// This file implements a generic `ObjectPool` for managing a fixed-size
// collection of objects of a given type `T`. This pool enables efficient
// acquisition and release of objects without incurring dynamic memory
// allocations, making it ideal for scenarios where object creation and
// destruction overhead is a concern (e.g., managing network packets or
// session objects). It utilizes a `StaticBitSet` to track used and free
// slots and includes a mutex to ensure thread-safe access to the pool.
//
const std = @import("std");

pub fn ObjectPool(comptime T: type, comptime Size: usize) type {
    return struct {
        const Self = @This();
        items: [Size]T = undefined,
        // Bitset tracks which slots are free (0) or used (1)
        used: std.StaticBitSet(Size) = std.StaticBitSet(Size).initEmpty(),

        /// thread-safe locking not strictly needed if single-threaded event loop,
        /// but good practice if you plan to thread transport.
        lock: std.Thread.Mutex = .{},

        pub fn acquire(self: *Self) ?*T {
            self.lock.lock();
            defer self.lock.unlock();

            // ❌ OLD: const idx = self.used.findFirstUnset() orelse return null;

            // ✅ NEW: Use iterator to find first unset bit (0)
            var it = self.used.iterator(.{ .kind = .unset });
            const idx = it.next() orelse return null;

            self.used.set(idx);
            return &self.items[idx];
        }

        pub fn release(self: *Self, ptr: *T) void {
            self.lock.lock();
            defer self.lock.unlock();

            // Calculate index based on pointer math
            const start_int = @intFromPtr(&self.items);
            const ptr_int = @intFromPtr(ptr);
            const idx = (ptr_int - start_int) / @sizeOf(T);

            self.used.unset(idx);
        }
    };
}
