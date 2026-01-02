// Delta-based CRDT store tracking service versions and gossip digest generation.
// This file implements a delta-based CRDT (Conflict-Free Replicated Data Type)
// store, specifically designed for tracking service versions within the Myco system.
// It defines the `ServiceStore` struct, a versioned key-value store that manages
// service states, records changes as "dirty" deltas, and maintains a history of
// recent updates. This module also provides functionalities for efficiently
// generating gossip digests through reservoir sampling, enabling robust
// synchronization of service information between nodes with minimal memory allocations.
//
const std = @import("std");
const Hlc = @import("hlc.zig").Hlc;
const limits = @import("../core/limits.zig");
const BoundedArray = @import("../util/bounded_array.zig").BoundedArray;
/// Digest entry advertised during sync exchanges.
pub const Entry = extern struct {
    id: u64,
    version: u64,
};
pub const StoreItem = struct {
    id: u64,
    version: u64,
    active: bool, // Used to mark "slots" as empty or full
};

/// Versioned key-value store for services with digest generation.
pub const ServiceStore = struct {
    //allocator: std.mem.Allocator,
    //versions: std.AutoHashMap(u64, u64),
    // dirty: std.ArrayListUnmanaged(Entry),

    items: [limits.MAX_SERVICES]StoreItem,
    dirty: BoundedArray(Entry, limits.MAX_SERVICES),
    recent: [limits.MAX_RECENT_DELTAS]Entry,
    recent_len: usize = 0,

    /// Create an empty store.
    pub fn init() ServiceStore {
        return .{
            .items = [_]StoreItem{.{ .id = 0, .version = 0, .active = false }} ** limits.MAX_SERVICES,
            .dirty = BoundedArray(Entry, limits.MAX_SERVICES).init(0) catch unreachable,
            .recent = undefined,
            .recent_len = 0,
        };
    }

    pub fn update(self: *ServiceStore, id: u64, version: u64) !bool {
        // 1. Linear Scan (Zero Alloc)
        for (&self.items) |*item| {
            if (item.active and item.id == id) {
                const current = item.version;
                if (current == 0 or Hlc.newer(Hlc.unpack(version), Hlc.unpack(current))) {
                    item.version = version;
                    self.recordDelta(.{ .id = id, .version = version });
                    return true;
                }
                return false;
            }
        }
        // 2. Insert into empty slot
        for (&self.items) |*item| {
            if (!item.active) {
                item.* = .{ .id = id, .version = version, .active = true };
                self.recordDelta(.{ .id = id, .version = version });
                return true;
            }
        }
        return error.StoreFull;
    }
    /// Get the known version of a service (0 if absent).
    pub fn getVersion(self: *const ServiceStore, id: u64) u64 {
        // Linear scan over fixed array (Zero Alloc)
        for (&self.items) |*item| {
            if (item.active and item.id == id) {
                return item.version;
            }
        }
        return 0;
    }
    // Add this new helper function for the API
    pub fn count(self: *const ServiceStore) usize {
        var c: usize = 0;
        for (&self.items) |*item| {
            if (item.active) c += 1;
        }
        return c;
    }

    /// Drain dirty updates into caller-provided buffer; returns number of entries copied.
    /// Drain dirty updates into caller-provided buffer; returns number of entries copied.
    pub fn drainDirty(self: *ServiceStore, out: []Entry) usize {
        // ❌ OLD: self.dirty.items.len
        // ✅ NEW: self.dirty.len
        const take = @min(out.len, self.dirty.len);
        if (take == 0) return 0;

        // Copy out
        std.mem.copyForwards(Entry, out[0..take], self.dirty.buffer[0..take]);

        const remain = self.dirty.len - take;
        if (remain > 0) {
            // Shift remaining items to the front
            std.mem.copyForwards(Entry, self.dirty.buffer[0..remain], self.dirty.buffer[take .. take + remain]);
        }
        self.dirty.len = remain;
        return take;
    }

    /// Copy the most recent deltas into caller-provided buffer (does not drain).
    pub fn copyRecent(self: *const ServiceStore, out: []Entry) usize {
        const take = @min(out.len, self.recent_len);
        if (take == 0) return 0;
        const start = self.recent_len - take;
        std.mem.copyForwards(Entry, out[0..take], self.recent[start .. start + take]);
        return take;
    }

    fn recordDelta(self: *ServiceStore, entry: Entry) void {
        self.pushDirty(entry);
        self.pushRecent(entry);
    }

    fn pushDirty(self: *ServiceStore, entry: Entry) void {
        self.dirty.append(entry) catch {
            // Drop oldest delta when saturated to keep most recent updates.
            if (self.dirty.len == 0) return;
            std.mem.copyForwards(Entry, self.dirty.buffer[0 .. self.dirty.len - 1], self.dirty.buffer[1..self.dirty.len]);
            self.dirty.len -= 1;
            self.dirty.append(entry) catch {};
        };
    }

    fn pushRecent(self: *ServiceStore, entry: Entry) void {
        if (self.recent_len < self.recent.len) {
            self.recent[self.recent_len] = entry;
            self.recent_len += 1;
            return;
        }
        // Shift left and append newest at the end.
        std.mem.copyForwards(Entry, self.recent[0 .. self.recent.len - 1], self.recent[1..self.recent.len]);
        self.recent[self.recent.len - 1] = entry;
    }
    /// Reservoir sampling over the fixed array to populate a gossip digest.
    /// Reservoir sampling over the fixed array to populate a gossip digest.
    pub fn populateDigest(self: *ServiceStore, buffer: []Entry, rand: std.Random) usize {
        const k = buffer.len;
        if (k == 0) return 0;

        // ❌ OLD: var count: usize = 0;
        // ✅ NEW: Renamed to avoid shadowing the count() function
        var added: usize = 0;

        var total_seen: usize = 0;

        // Iterate over the fixed slab
        for (&self.items) |*item| {
            if (!item.active) continue;

            // 1. Fill Reservoir
            if (added < k) {
                buffer[added] = .{ .id = item.id, .version = item.version };
                added += 1;
            } else {
                // 2. Random Replacement (Reservoir Sampling)
                const j = rand.intRangeAtMost(usize, 0, total_seen);
                if (j < k) {
                    buffer[j] = .{ .id = item.id, .version = item.version };
                }
            }
            total_seen += 1;
        }

        return added;
    }
};
