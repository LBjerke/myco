//! ServiceStore - CRDT-based service management with HLC timestamps.
//!
//! Implements Last-Writer-Wins CRDT semantics using Hybrid Logical Clocks.
//! Provides automatic conflict resolution and dirty tracking for gossip.

const std = @import("std");
const hlc = @import("../net/hlc.zig");
const Timestamp = hlc.Timestamp;
const limits = @import("../util/limits.zig");
const name_table = @import("../net/name_table.zig");

/// Marker for "not found" in index.
const index_not_found: u16 = 0xFFFF;

/// Maximum number of dirty services tracked for sync.
const max_dirty_services: usize = 64;

/// Service state with CRDT metadata.
pub const ServiceState = struct {
    service_id: u16,

    /// Index into name table.
    name_index: u8 = 0,

    /// Number of replicas.
    replicas: u8 = 0,

    /// Hash of the full spec.
    spec_hash: u64 = 0,

    /// Platform requirements mask.
    platform_mask: u16 = 0,

    /// Hash of placement constraints.
    constraints_hash: u64 = 0,

    /// HLC timestamp for conflict resolution.
    version: Timestamp = .{ .time = 0, .count = 0, .node_id = 0 },

    /// Whether this slot is active.
    active: bool = false,
};

/// Dirty entry for services.
const DirtyEntry = struct {
    service_id: u16,
    version: Timestamp,
};

/// ServiceStore - CRDT-based service management.
pub const ServiceStore = struct {
    /// Service states.
    services: [limits.max_services]ServiceState,

    /// Current service count.
    service_count: usize = 0,

    /// Index for O(1) lookup: service_index[service_id] → index in services array.
    /// 0xFFFF means not found.
    service_index: [limits.max_services + 1]u16,

    /// Dirty buffer - services changed since last sync.
    dirty_services: [max_dirty_services]DirtyEntry,

    /// Number of dirty entries.
    dirty_count: usize = 0,

    /// Initialize empty ServiceStore.
    pub fn init() ServiceStore {
        return ServiceStore{
            .services = undefined,
            .service_count = 0,
            .service_index = undefined,
            .dirty_services = undefined,
            .dirty_count = 0,
        };
    }

    /// Initialize index arrays to "not found" marker.
    pub fn reset(store: *ServiceStore) void {
        store.service_count = 0;
        store.dirty_count = 0;
        for (&store.service_index) |*entry| {
            entry.* = index_not_found;
        }
    }

    /// Update service state with LWW semantics.
    /// Returns true if update was applied.
    pub fn update(store: *ServiceStore, state: ServiceState) bool {
        const service_id = state.service_id;
        const idx = store.service_index[service_id];

        // If new service or incoming is newer, apply
        if (idx == index_not_found) {
            // New service - add at end
            const new_idx = store.service_count;
            store.services[new_idx] = state;
            store.service_index[service_id] = @truncate(new_idx);
            store.service_count += 1;
            store.markDirty(service_id, state.version);
            return true;
        }

        // Check version - apply if incoming is newer
        if (Timestamp.lessThan(store.services[idx].version, state.version)) {
            store.services[idx] = state;
            store.markDirty(service_id, state.version);
            return true;
        }

        return false;
    }

    /// Merge remote service state (for gossip).
    pub fn merge(store: *ServiceStore, remote: ServiceState) bool {
        return store.update(remote);
    }

    /// Remove service (marks as inactive with tombstone).
    pub fn remove(store: *ServiceStore, service_id: u16, version: Timestamp) bool {
        const idx = store.service_index[service_id];
        if (idx == index_not_found) {
            return false;
        }

        // Create tombstone
        var tombstone = store.services[idx];
        tombstone.active = false;
        tombstone.version = version;

        // Apply if newer
        if (Timestamp.lessThan(store.services[idx].version, version)) {
            store.services[idx] = tombstone;
            store.markDirty(service_id, version);
            return true;
        }

        return false;
    }

    /// Drain dirty services for sync.
    /// Returns number of services written to output slice.
    pub fn drainDirty(store: *ServiceStore, out: []ServiceState) usize {
        const count = @min(store.dirty_count, out.len);
        for (0..count) |i| {
            const service_id = store.dirty_services[i].service_id;
            const idx = store.service_index[service_id];
            out[i] = store.services[idx];
        }
        store.dirty_count = 0;
        return count;
    }

    /// Find service by ID using O(1) index lookup.
    pub fn find(store: *const ServiceStore, service_id: u16) ?*const ServiceState {
        const idx = store.service_index[service_id];
        if (idx == index_not_found) {
            return null;
        }
        return &store.services[idx];
    }

    /// Mark service as dirty for sync.
    fn markDirty(store: *ServiceStore, service_id: u16, version: Timestamp) void {
        // Check if already dirty
        for (store.dirty_services[0..store.dirty_count]) |entry| {
            if (entry.service_id == service_id) return;
        }

        // Add to dirty buffer if there's room
        if (store.dirty_count < max_dirty_services) {
            store.dirty_services[store.dirty_count] = .{
                .service_id = service_id,
                .version = version,
            };
            store.dirty_count += 1;
        }
    }

    /// Check if store is empty.
    pub fn isEmpty(store: *const ServiceStore) bool {
        return store.service_count == 0;
    }

    /// Get service name by name_index.
    pub fn getServiceName(_: *const ServiceStore, name_index: u8, nt: *const name_table.NameTable) []const u8 {
        return nt.get(name_index);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ServiceStore.init returns empty store" {
    const store = ServiceStore.init();

    try std.testing.expectEqual(@as(usize, 0), store.service_count);
    try std.testing.expectEqual(@as(usize, 0), store.dirty_count);
}

test "ServiceStore.update adds new service" {
    var store = ServiceStore.init();
    store.reset();

    const service = ServiceState{
        .service_id = 1,
        .name_index = 1,
        .replicas = 3,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };

    const updated = store.update(service);
    try std.testing.expectEqual(true, updated);
    try std.testing.expectEqual(@as(usize, 1), store.service_count);
    try std.testing.expectEqual(@as(usize, 1), store.dirty_count);
}

test "ServiceStore.update applies newer version" {
    var store = ServiceStore.init();
    store.reset();

    // Add initial service
    const older = ServiceState{
        .service_id = 1,
        .name_index = 1,
        .replicas = 2,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(older);

    // Update with newer version
    const newer = ServiceState{
        .service_id = 1,
        .name_index = 1,
        .replicas = 5,
        .version = .{ .time = 2000, .count = 1, .node_id = 0 },
        .active = true,
    };
    const updated = store.update(newer);

    try std.testing.expectEqual(true, updated);
    try std.testing.expectEqual(@as(u8, 5), store.services[0].replicas);
}

test "ServiceStore.update rejects older version" {
    var store = ServiceStore.init();
    store.reset();

    // Add initial service
    const newer = ServiceState{
        .service_id = 1,
        .name_index = 1,
        .replicas = 5,
        .version = .{ .time = 2000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(newer);

    // Try to update with older version
    const older = ServiceState{
        .service_id = 1,
        .name_index = 1,
        .replicas = 2,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    const updated = store.update(older);

    try std.testing.expectEqual(false, updated);
    try std.testing.expectEqual(@as(u8, 5), store.services[0].replicas);
}

test "ServiceStore.find returns service by ID" {
    var store = ServiceStore.init();
    store.reset();

    const service = ServiceState{
        .service_id = 42,
        .name_index = 1,
        .replicas = 3,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(service);

    const found = store.find(42);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u16, 42), found.?.service_id);
}

test "ServiceStore.find returns null for missing" {
    const store = ServiceStore.init();

    const found = store.find(999);
    try std.testing.expectEqual(null, found);
}

test "ServiceStore.drainDirty returns changed services" {
    var store = ServiceStore.init();
    store.reset();

    // Add some services
    _ = store.update(.{ .service_id = 1, .version = .{ .time = 1, .count = 0, .node_id = 0 }, .active = true });
    _ = store.update(.{ .service_id = 2, .version = .{ .time = 2, .count = 0, .node_id = 0 }, .active = true });
    _ = store.update(.{ .service_id = 3, .version = .{ .time = 3, .count = 0, .node_id = 0 }, .active = true });

    var buf: [10]ServiceState = undefined;
    const drained = store.drainDirty(&buf);

    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expectEqual(@as(usize, 0), store.dirty_count);
}

test "ServiceStore.remove sets tombstone" {
    var store = ServiceStore.init();
    store.reset();

    // Add service
    _ = store.update(.{ .service_id = 1, .version = .{ .time = 1000, .count = 0, .node_id = 0 }, .active = true });

    // Remove with newer version
    _ = store.remove(1, .{ .time = 2000, .count = 0, .node_id = 0 });

    const found = store.find(1);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(false, found.?.active);
}
