// CRDT store tracking service versions and gossip digest generation.
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

    /// Create an empty store.
    pub fn init() ServiceStore {
        return .{
            .items = [_]StoreItem{.{ .id = 0, .version = 0, .active = false }} ** limits.MAX_SERVICES,
            .dirty = BoundedArray(Entry, limits.MAX_SERVICES).init(0) catch unreachable,
        };
    }

    pub fn update(self: *ServiceStore, id: u64, version: u64) !bool {
        // 1. Linear Scan (Zero Alloc)
        for (&self.items) |*item| {
            if (item.active and item.id == id) {
                // Compare HLC versions...
                // Update if newer...
                return true;
            }
        }
        // 2. Insert into empty slot
        for (&self.items) |*item| {
            if (!item.active) {
                item.* = .{ .id = id, .version = version, .active = true };
                self.dirty.append(.{ .id = id, .version = version }) catch return error.StoreFull;
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
