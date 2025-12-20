// CRDT store tracking service versions and gossip digest generation.
const std = @import("std");
const Hlc = @import("hlc.zig").Hlc;

/// Digest entry advertised during sync exchanges.
pub const Entry = extern struct {
    id: u64,
    version: u64,
};

/// Fixed-capacity service store for zero-alloc mode. Not yet wired into Node; kept
/// alongside the existing allocator-backed store so we can migrate safely.
pub fn FixedServiceStore(comptime max_items: usize) type {
    return struct {
        const Self = @This();

        entries: [max_items]Entry = [_]Entry{.{ .id = 0, .version = 0 }} ** max_items,
        len: usize = 0,

        // Track dirty updates to generate digests without allocations.
        dirty: [max_items]Entry = [_]Entry{.{ .id = 0, .version = 0 }} ** max_items,
        dirty_len: usize = 0,

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn init() Self {
            return .{};
        }

        fn findIndex(self: *const Self, id: u64) ?usize {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.entries[i].id == id) return i;
            }
            return null;
        }

        /// Insert or update; returns true if state changed.
        pub fn update(self: *Self, id: u64, version: u64) !bool {
            if (self.findIndex(id)) |idx| {
                const current = self.entries[idx].version;
                if (!Hlc.newer(Hlc.unpack(version), Hlc.unpack(current))) return false;
                self.entries[idx].version = version;
            } else {
                if (self.len == max_items) return error.TableFull;
                self.entries[self.len] = .{ .id = id, .version = version };
                self.len += 1;
            }

            if (self.dirty_len < self.dirty.len) {
                self.dirty[self.dirty_len] = .{ .id = id, .version = version };
                self.dirty_len += 1;
            }
            return true;
        }

        pub fn getVersion(self: *const Self, id: u64) u64 {
            if (self.findIndex(id)) |idx| {
                return self.entries[idx].version;
            }
            return 0;
        }

        pub fn drainDirty(self: *Self, out: []Entry) usize {
            const take = @min(out.len, self.dirty_len);
            if (take == 0) return 0;

            std.mem.copyForwards(Entry, out[0..take], self.dirty[0..take]);
            const remain = self.dirty_len - take;
            if (remain > 0) {
                std.mem.copyForwards(Entry, self.dirty[0..remain], self.dirty[take .. take + remain]);
            }
            self.dirty_len = remain;
            return take;
        }

        /// Reservoir sampling over the fixed entries to populate a digest buffer.
        pub fn populateDigest(self: *const Self, buffer: []Entry, rand: std.Random) usize {
            const k = buffer.len;
            if (k == 0 or self.len == 0) return 0;

            const first = @min(k, self.len);
            std.mem.copyForwards(Entry, buffer[0..first], self.entries[0..first]);
            if (self.len <= k) return self.len;

            var i: usize = first;
            while (i < self.len) : (i += 1) {
                const j = rand.intRangeAtMost(usize, 0, i);
                if (j < k) {
                    buffer[j] = self.entries[i];
                }
            }
            return k;
        }

        pub const Iterator = struct {
            store: *const Self,
            idx: usize = 0,

            pub fn next(self: *Iterator) ?struct { key_ptr: *const u64, value_ptr: *const u64 } {
                while (self.idx < self.store.len) : (self.idx += 1) {
                    const entry = &self.store.entries[self.idx];
                    if (entry.id == 0) continue;
                    const key_ptr: *const u64 = &entry.id;
                    const value_ptr: *const u64 = &entry.version;
                    self.idx += 1;
                    return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .store = self };
        }
    };
}

/// Versioned key-value store for services with digest generation.
pub const ServiceStore = struct {
    allocator: std.mem.Allocator,
    versions: std.AutoHashMap(u64, u64),
    dirty: std.ArrayListUnmanaged(Entry),

    pub fn count(self: *const ServiceStore) usize {
        return self.versions.count();
    }

    pub fn iterator(self: *ServiceStore) std.AutoHashMap(u64, u64).Iterator {
        return self.versions.iterator();
    }

    /// Create an empty store.
    pub fn init(allocator: std.mem.Allocator) ServiceStore {
        return .{
            .allocator = allocator,
            .versions = std.AutoHashMap(u64, u64).init(allocator),
            .dirty = .{},
        };
    }

    /// Release internal allocations.
    pub fn deinit(self: *ServiceStore) void {
        self.versions.deinit();
        self.dirty.deinit(self.allocator);
    }

    /// Insert or bump the version for a service; returns true if it changed state.
    pub fn update(self: *ServiceStore, id: u64, version: u64) !bool {
        const result = try self.versions.getOrPut(id);
        if (!result.found_existing) {
            result.value_ptr.* = version;
            try self.dirty.append(self.allocator, .{ .id = id, .version = version });
            return true;
        } else if (Hlc.newer(Hlc.unpack(version), Hlc.unpack(result.value_ptr.*))) {
            result.value_ptr.* = version;
            try self.dirty.append(self.allocator, .{ .id = id, .version = version });
            return true;
        }
        return false;
    }

    /// Get the known version of a service (0 if absent).
    pub fn getVersion(self: *ServiceStore, id: u64) u64 {
        return self.versions.get(id) orelse 0;
    }

    /// Drain dirty updates into caller-provided buffer; returns number of entries copied.
    pub fn drainDirty(self: *ServiceStore, out: []Entry) usize {
        const take = @min(out.len, self.dirty.items.len);
        if (take == 0) return 0;

        std.mem.copyForwards(Entry, out[0..take], self.dirty.items[0..take]);

        const remain = self.dirty.items.len - take;
        if (remain > 0) {
            std.mem.copyForwards(Entry, self.dirty.items[0..remain], self.dirty.items[take .. take + remain]);
        }
        self.dirty.items.len = remain;
        return take;
    }

    /// FIX: Implement true random sampling using the Reservoir Sampling algorithm.
    /// This is a zero-allocation, single-pass algorithm that guarantees a fair sample.
    pub fn populateDigest(self: *ServiceStore, buffer: []Entry, rand: std.Random) usize {
        const k = buffer.len;
        if (k == 0) return 0;

        var filled: usize = 0;
        var it = self.versions.iterator();

        // 1. Fill the reservoir (the buffer) with the first 'k' items.
        while (filled < k) {
            const kv = it.next() orelse break;
            buffer[filled] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            filled += 1;
        }

        // If the map had fewer items than the buffer, we're done.
        if (filled < k) {
            return filled;
        }

        // 2. For all remaining items in the stream (from k+1 to n)...
        // 'i' represents the total number of items seen so far.
        var i = k;
        while (it.next()) |kv| {
            // Generate a random number 'j' between 0 and 'i'.
            const j = rand.intRangeAtMost(usize, 0, i);

            // If 'j' falls within the reservoir's bounds (0 to k-1)...
            if (j < k) {
                // ...replace the element at that position.
                buffer[j] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            }
            i += 1;
        }

        return k;
    }
};
