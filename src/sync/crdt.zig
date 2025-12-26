// CRDT store tracking service versions and gossip digest generation.
const std = @import("std");
const Hlc = @import("hlc.zig").Hlc;

/// Digest entry advertised during sync exchanges.
pub const Entry = extern struct {
    id: u64,
    version: u64,
};

/// Versioned key-value store for services with digest generation.
pub const ServiceStore = struct {
    allocator: std.mem.Allocator,
    versions: std.AutoHashMap(u64, u64),
    dirty: std.ArrayListUnmanaged(Entry),

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

        var count: usize = 0;
        var it = self.versions.iterator();

        // 1. Fill the reservoir (the buffer) with the first 'k' items.
        while (count < k) {
            const kv = it.next() orelse break;
            buffer[count] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            count += 1;
        }

        // If the map had fewer items than the buffer, we're done.
        if (count < k) {
            return count;
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
