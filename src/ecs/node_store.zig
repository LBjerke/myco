//! NodeStore - CRDT-based node management with HLC timestamps.
//!
//! Implements Last-Writer-Wins CRDT semantics using Hybrid Logical Clocks.
//! Provides automatic conflict resolution and dirty tracking for gossip.

const std = @import("std");
const hlc = @import("../net/hlc.zig");
const Timestamp = hlc.Timestamp;
const limits = @import("../util/limits.zig");

/// Marker for "not found" in index.
const index_not_found: u16 = 0xFFFF;

/// Maximum number of dirty nodes tracked for sync.
const max_dirty_nodes: usize = 64;

/// Node state with CRDT metadata.
pub const NodeState = struct {
    node_id: u16,

    /// IP address bytes.
    address: [4]u8 = .{ 0, 0, 0, 0 },

    /// Port number.
    port: u16 = 0,

    /// Platform identifier.
    platform: u8 = 0,

    /// Health status.
    health: u8 = 0,

    /// HLC timestamp for conflict resolution.
    version: Timestamp = .{ .time = 0, .count = 0, .node_id = 0 },

    /// Whether this slot is active.
    active: bool = false,
};

/// NodeStore - CRDT-based node management.
pub const NodeStore = struct {
    /// Node states.
    nodes: [limits.max_nodes]NodeState,

    /// Current node count.
    node_count: usize = 0,

    /// Index for O(1) lookup: node_index[node_id] → index in nodes array.
    /// 0xFFFF means not found.
    node_index: [limits.max_nodes + 1]u16,

    /// Dirty buffer - nodes changed since last sync.
    dirty_nodes: [max_dirty_nodes]u16,

    /// Number of dirty entries.
    dirty_count: usize = 0,

    /// Initialize empty NodeStore.
    pub fn init() NodeStore {
        return NodeStore{
            .nodes = undefined,
            .node_count = 0,
            .node_index = undefined,
            .dirty_nodes = undefined,
            .dirty_count = 0,
        };
    }

    /// Initialize index arrays to "not found" marker.
    pub fn reset(store: *NodeStore) void {
        store.node_count = 0;
        store.dirty_count = 0;
        for (&store.node_index) |*entry| {
            entry.* = index_not_found;
        }
    }

    /// Update node state with LWW semantics.
    /// Returns true if update was applied.
    pub fn update(store: *NodeStore, state: NodeState) bool {
        const node_id = state.node_id;
        const idx = store.node_index[node_id];

        // If new node or incoming is newer, apply
        if (idx == index_not_found) {
            // New node - add at end
            const new_idx = store.node_count;
            store.nodes[new_idx] = state;
            store.node_index[node_id] = @truncate(new_idx);
            store.node_count += 1;
            store.markDirty(node_id);
            return true;
        }

        // Check version - apply if incoming is newer
        if (Timestamp.lessThan(store.nodes[idx].version, state.version)) {
            store.nodes[idx] = state;
            store.markDirty(node_id);
            return true;
        }

        return false;
    }

    /// Merge remote node state (for gossip).
    pub fn merge(store: *NodeStore, remote: NodeState) bool {
        return store.update(remote);
    }

    /// Remove node (marks as inactive with tombstone).
    pub fn remove(store: *NodeStore, node_id: u16, version: Timestamp) bool {
        const idx = store.node_index[node_id];
        if (idx == index_not_found) {
            return false;
        }

        // Create tombstone
        var tombstone = store.nodes[idx];
        tombstone.active = false;
        tombstone.version = version;

        // Apply if newer
        if (Timestamp.lessThan(store.nodes[idx].version, version)) {
            store.nodes[idx] = tombstone;
            store.markDirty(node_id);
            return true;
        }

        return false;
    }

    /// Drain dirty nodes for sync.
    /// Returns number of nodes written to output slice.
    pub fn drainDirty(store: *NodeStore, out: []NodeState) usize {
        const count = @min(store.dirty_count, out.len);
        for (0..count) |i| {
            const node_id = store.dirty_nodes[i];
            const idx = store.node_index[node_id];
            out[i] = store.nodes[idx];
        }
        store.dirty_count = 0;
        return count;
    }

    /// Find node by ID using O(1) index lookup.
    pub fn find(store: *const NodeStore, node_id: u16) ?*const NodeState {
        const idx = store.node_index[node_id];
        if (idx == index_not_found) {
            return null;
        }
        return &store.nodes[idx];
    }

    /// Mark node as dirty for sync.
    fn markDirty(store: *NodeStore, node_id: u16) void {
        // Check if already dirty
        for (store.dirty_nodes[0..store.dirty_count]) |dirty_id| {
            if (dirty_id == node_id) return;
        }

        // Add to dirty buffer if there's room
        if (store.dirty_count < max_dirty_nodes) {
            store.dirty_nodes[store.dirty_count] = node_id;
            store.dirty_count += 1;
        }
    }

    /// Check if store is empty.
    pub fn isEmpty(store: *const NodeStore) bool {
        return store.node_count == 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NodeStore.init returns empty store" {
    const store = NodeStore.init();

    try std.testing.expectEqual(@as(usize, 0), store.node_count);
    try std.testing.expectEqual(@as(usize, 0), store.dirty_count);
}

test "NodeStore.update adds new node" {
    var store = NodeStore.init();
    store.reset();

    const node = NodeState{
        .node_id = 1,
        .address = .{ 192, 168, 1, 100 },
        .port = 8080,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };

    const updated = store.update(node);
    try std.testing.expectEqual(true, updated);
    try std.testing.expectEqual(@as(usize, 1), store.node_count);
    try std.testing.expectEqual(@as(usize, 1), store.dirty_count);
}

test "NodeStore.update applies newer version" {
    var store = NodeStore.init();
    store.reset();

    // Add initial node
    const older = NodeState{
        .node_id = 1,
        .address = .{ 192, 168, 1, 100 },
        .port = 8080,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(older);

    // Update with newer version
    const newer = NodeState{
        .node_id = 1,
        .address = .{ 192, 168, 1, 101 },
        .port = 9090,
        .version = .{ .time = 2000, .count = 1, .node_id = 0 },
        .active = true,
    };
    const updated = store.update(newer);

    try std.testing.expectEqual(true, updated);
    try std.testing.expectEqual(@as(u16, 9090), store.nodes[0].port);
}

test "NodeStore.update rejects older version" {
    var store = NodeStore.init();
    store.reset();

    // Add initial node
    const newer = NodeState{
        .node_id = 1,
        .address = .{ 192, 168, 1, 100 },
        .port = 8080,
        .version = .{ .time = 2000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(newer);

    // Try to update with older version
    const older = NodeState{
        .node_id = 1,
        .address = .{ 192, 168, 1, 99 },
        .port = 7070,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    const updated = store.update(older);

    try std.testing.expectEqual(false, updated);
    try std.testing.expectEqual(@as(u16, 8080), store.nodes[0].port);
}

test "NodeStore.find returns node by ID" {
    var store = NodeStore.init();
    store.reset();

    const node = NodeState{
        .node_id = 42,
        .address = .{ 10, 0, 0, 1 },
        .port = 3000,
        .version = .{ .time = 1000, .count = 1, .node_id = 0 },
        .active = true,
    };
    _ = store.update(node);

    const found = store.find(42);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u16, 42), found.?.node_id);
}

test "NodeStore.find returns null for missing" {
    const store = NodeStore.init();

    const found = store.find(999);
    try std.testing.expectEqual(null, found);
}

test "NodeStore.drainDirty returns changed nodes" {
    var store = NodeStore.init();
    store.reset();

    // Add some nodes
    _ = store.update(.{ .node_id = 1, .version = .{ .time = 1, .count = 0, .node_id = 0 }, .active = true });
    _ = store.update(.{ .node_id = 2, .version = .{ .time = 2, .count = 0, .node_id = 0 }, .active = true });
    _ = store.update(.{ .node_id = 3, .version = .{ .time = 3, .count = 0, .node_id = 0 }, .active = true });

    var buf: [10]NodeState = undefined;
    const drained = store.drainDirty(&buf);

    try std.testing.expectEqual(@as(usize, 3), drained);
    try std.testing.expectEqual(@as(usize, 0), store.dirty_count);
}

test "NodeStore.remove sets tombstone" {
    var store = NodeStore.init();
    store.reset();

    // Add node
    _ = store.update(.{ .node_id = 1, .version = .{ .time = 1000, .count = 0, .node_id = 0 }, .active = true });

    // Remove with newer version
    _ = store.remove(1, .{ .time = 2000, .count = 0, .node_id = 0 });

    const found = store.find(1);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(false, found.?.active);
}
