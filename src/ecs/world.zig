//! ECS World - the core state container.
//!
//! This module contains all ECS components for Myco:
//! - Node, NodeMeta, NodeHealth - node-related data
//! - ServiceSpec, ServiceRuntime, ServicePlacement - service-related data
//!
//! Components are organized by:
//! - Replicated (synced via gossip): NodeMeta, ServiceSpec, ServicePlacement
//! - Local only (not synced): NodeHealth, ServiceRuntime

const std = @import("std");
const limits = @import("../util/limits.zig");
const hlc = @import("../net/hlc.zig");
const name_table = @import("../net/name_table.zig");
const NameTable = name_table.NameTable;
const Timestamp = hlc.Timestamp;
const assert = @import("../util/assert.zig");

// ============================================================================
// Node Components
// ============================================================================

/// Node health status enum.
pub const NodeHealthStatus = enum(u8) {
    healthy = 0,
    degraded = 1,
    unhealthy = 2,
    unknown = 3,
};

/// Platform type for nodes.
pub const Platform = enum(u8) {
    linux_x64 = 1,
    linux_arm64 = 2,
    linux_arm = 3,
    darwin_x64 = 4,
    darwin_arm64 = 5,
    unknown = 0,
};

/// Node entity representation (basic identity).
pub const Node = struct {
    node_id: u16,
    alive: bool,
};

/// Node metadata - replicated across cluster via gossip.
/// Used for placement decisions and capacity planning.
pub const NodeMeta = struct {
    node_id: u16,

    /// Available resources (in MB)
    cpu_mhz: u32 = 0,
    mem_free_mb: u32 = 0,
    disk_free_mb: u32 = 0,

    /// Platform (linux_arm64, darwin_x64, etc.)
    platform: Platform = .unknown,

    /// When this metadata was last updated (HLC timestamp)
    version: Timestamp = .{ .time = 0, .count = 0, .node_id = 0 },

    /// Last time we heard from this node (wall clock, for TTL)
    last_seen_ms: u64 = 0,

    /// Whether this slot is active
    active: bool = false,
};

/// Node health component - local only, not replicated.
/// Tracks heartbeat and health check failures.
pub const NodeHealth = struct {
    node_id: u16,
    status: NodeHealthStatus = .unknown,
    last_heartbeat_ms: u64 = 0,
    health_check_failures: u8 = 0,
};

// ============================================================================
// Service Components
// ============================================================================

/// Service specification - replicated summary.
/// Small enough to fit in gossip packets.
/// Uses name_index into the World's NameTable.
pub const ServiceSpec = struct {
    service_id: u16,

    /// Index into World.name_table (1 byte instead of pointer + length)
    name_index: u8,

    replicas: u8,

    /// Hash of the full spec (for fetching spec blob)
    spec_hash: u64 = 0,

    /// Platform requirements (bitmask of Platform enum values)
    platform_mask: u16 = 0,

    /// Hash of placement constraints
    constraints_hash: u64 = 0,

    /// HLC version for CRDT merge
    version: Timestamp = .{ .time = 0, .count = 0, .node_id = 0 },

    /// Whether this slot is active
    active: bool = false,
};

/// Service runtime - local only, not replicated.
/// Tracks actual running state on THIS node.
pub const ServiceRuntime = struct {
    service_id: u16,

    /// Is the service currently running?
    running: bool = false,

    /// systemd unit name (if running)
    unit_name: []const u8 = &[_]u8{},

    /// When the service was last started (ms since epoch)
    last_start_ms: u64 = 0,

    /// Last exit code (0 = still running or success)
    last_exit_code: u8 = 0,

    /// Current backoff level (for restart throttling)
    backoff_level: u8 = 0,

    /// Whether this slot is active
    active: bool = false,
};

/// Service placement - which node owns which replica.
/// Replicated across cluster via gossip.
pub const ServicePlacement = struct {
    /// Service ID
    service_id: u16,

    /// Replica index (0 to replicas-1)
    replica_id: u8,

    /// Node ID that owns this replica
    node_id: u16 = 0,

    /// Monotonic counter for lease epochs
    lease_epoch: u32 = 0,

    /// When this lease expires (ms since epoch, 0 = no expiry)
    expires_at_ms: u64 = 0,

    /// Score used when making placement decision
    score: i16 = 0,

    /// HLC version for CRDT merge
    version: Timestamp = .{ .time = 0, .count = 0, .node_id = 0 },

    /// Whether this slot is active (has a placement)
    active: bool = false,
};

// ============================================================================
// World - Container for all components
// ============================================================================

/// Marker for "not found" in index arrays.
const index_not_found: u16 = 0xFFFF;

/// The ECS World - holds all component tables.
///
/// Organized as:
/// - Replicated components: NodeMeta, ServiceSpec, ServicePlacement
/// - Local components: NodeHealth, ServiceRuntime
pub const World = struct {
    // -------------------------------------------------------------------------
    // Node components
    // -------------------------------------------------------------------------

    /// Nodes in the cluster (basic identity).
    nodes: [limits.max_nodes]Node,
    node_count: usize = 0,

    /// Index for O(1) node lookups: node_index[node_id] → index in nodes array.
    /// 0xFFFF means not found. Size is max_nodes + 1 to handle node_id 0 as placeholder.
    node_index: [limits.max_nodes + 1]u16,

    /// Node metadata (replicated).
    node_metas: [limits.max_nodes]NodeMeta,
    node_meta_count: usize = 0,

    /// Node health (local only).
    node_health: [limits.max_nodes]NodeHealth,
    node_health_count: usize = 0,

    // -------------------------------------------------------------------------
    // Service components
    // -------------------------------------------------------------------------

    /// Service specifications (replicated).
    services: [limits.max_services]ServiceSpec,
    service_count: usize = 0,

    /// Index for O(1) service lookups: service_index[service_id] → index in services array.
    /// 0xFFFF means not found. Size is max_services + 1 to handle service_id 0 as placeholder.
    service_index: [limits.max_services + 1]u16,

    /// Name table for service names (replaces dynamic string allocation).
    name_table: NameTable,

    /// Service runtime (local only).
    service_runtimes: [limits.max_services]ServiceRuntime,
    service_runtime_count: usize = 0,

    /// Service placements (replicated).
    placements: [limits.max_placements]ServicePlacement,
    placement_count: usize = 0,

    /// Initialize a new empty World.
    ///
    /// Note: Arrays are initialized with `undefined` for performance reasons.
    /// This is safe because:
    /// 1. All count fields are explicitly set to 0
    /// 2. Code only accesses indices 0..count
    /// 3. The unused slots never need to be read
    ///
    /// Index arrays are explicitly initialized to index_not_found (0xFFFF).
    pub fn init() World {
        var world = World{
            // Node components - using undefined is safe: only 0..node_count is accessed
            .nodes = undefined,
            .node_count = 0,
            .node_index = undefined,
            .node_metas = undefined,
            .node_meta_count = 0,
            .node_health = undefined,
            .node_health_count = 0,

            // Service components - using undefined is safe: only 0..service_count is accessed
            .services = undefined,
            .service_count = 0,
            .service_index = undefined,
            .service_runtimes = undefined,
            .service_runtime_count = 0,
            .placements = undefined,
            .placement_count = 0,

            // Name table - zero initialize all entries for safety
            .name_table = std.mem.zeroInit(NameTable, .{}),
        };

        // Initialize index arrays to "not found" marker
        for (&world.node_index) |*entry| {
            entry.* = index_not_found;
        }
        for (&world.service_index) |*entry| {
            entry.* = index_not_found;
        }

        return world;
    }

    // -------------------------------------------------------------------------
    // Helper methods for finding components
    // -------------------------------------------------------------------------

    /// Find a node by ID using O(1) index lookup.
    pub fn findNode(self: *const World, node_id: u16) ?*const Node {
        // NASA Power of 10 Rule 5: Assert valid node_id
        assert.assert(node_id != 0, "findNode: node_id must not be zero");

        // Bounds check: node_id must be within the index array
        if (node_id > limits.max_nodes) return null;

        const idx = self.node_index[node_id];
        if (idx == index_not_found) return null;
        return &self.nodes[idx];
    }

    /// Find node metadata by ID.
    pub fn findNodeMeta(self: *const World, node_id: u16) ?*const NodeMeta {
        // NASA Power of 10 Rule 5: Assert valid node_id
        assert.assert(node_id != 0, "findNodeMeta: node_id must not be zero");

        for (self.node_metas[0..self.node_meta_count]) |*meta| {
            if (meta.node_id == node_id and meta.active) return meta;
        }
        return null;
    }

    /// Find a service by ID using O(1) index lookup.
    pub fn findService(self: *const World, service_id: u16) ?*const ServiceSpec {
        // NASA Power of 10 Rule 5: Assert valid service_id
        assert.assert(service_id != 0, "findService: service_id must not be zero");

        // Bounds check: service_id must be within the index array
        if (service_id > limits.max_services) return null;

        const idx = self.service_index[service_id];
        if (idx == index_not_found) return null;
        return &self.services[idx];
    }

    /// Find placement by service + replica.
    pub fn findPlacement(
        self: *const World,
        service_id: u16,
        replica_id: u8,
    ) ?*const ServicePlacement {
        // NASA Power of 10 Rule 5: Assert valid IDs
        assert.assert(service_id != 0, "findPlacement: service_id must not be zero");

        for (self.placements[0..self.placement_count]) |*placement| {
            if (placement.service_id == service_id and
                placement.replica_id == replica_id and
                placement.active)
            {
                return placement;
            }
        }
        return null;
    }

    /// Find all placements for a service.
    pub fn findPlacementsForService(self: *const World, service_id: u16) []ServicePlacement {
        var result: [limits.max_replicas_per_service]ServicePlacement = undefined;
        var count: usize = 0;

        for (self.placements[0..self.placement_count]) |*placement| {
            if (placement.service_id == service_id and placement.active) {
                if (count < limits.max_replicas_per_service) {
                    result[count] = placement.*;
                    count += 1;
                }
            }
        }

        return result[0..count];
    }

    /// Validate world state after WAL replay.
    /// Returns an error if the world state is invalid.
    pub fn validate(self: *const World) !void {
        try self.validateNodes();
        try self.validateServices();
        try self.validatePlacements();
    }

    /// Update node index after adding a node.
    /// Called by reducer when adding a node to the world.
    pub fn indexNode(self: *World, node_id: u16, array_index: usize) void {
        self.node_index[node_id] = @truncate(array_index);
    }

    /// Clear node index after removing a node.
    /// Called by reducer when removing a node from the world.
    pub fn unindexNode(self: *World, node_id: u16) void {
        self.node_index[node_id] = index_not_found;
    }

    /// Update service index after adding a service.
    /// Called by reducer when adding a service to the world.
    pub fn indexService(self: *World, service_id: u16, array_index: usize) void {
        self.service_index[service_id] = @truncate(array_index);
    }

    /// Clear service index after removing a service.
    /// Called by reducer when removing a service from the world.
    pub fn unindexService(self: *World, service_id: u16) void {
        self.service_index[service_id] = index_not_found;
    }

    /// Add a node at a sorted position (by node_id).
    /// Shifts existing elements and updates indices.
    pub fn addNodeSorted(self: *World, node: Node) !void {
        // Find insertion position (sorted by node_id)
        var insert_pos: usize = 0;
        for (self.nodes[0..self.node_count]) |existing| {
            if (existing.node_id > node.node_id) break;
            insert_pos += 1;
        }

        // Shift existing entries
        var shift_pos = self.node_count;
        while (shift_pos > insert_pos) : (shift_pos -= 1) {
            const from_idx = shift_pos - 1;
            self.nodes[shift_pos] = self.nodes[from_idx];
            self.node_index[self.nodes[from_idx].node_id] = @truncate(shift_pos);
        }

        // Insert at position
        self.nodes[insert_pos] = node;
        self.indexNode(node.node_id, insert_pos);
        self.node_count += 1;
    }

    /// Add a service at a sorted position (by service_id).
    /// Shifts existing elements and updates indices.
    pub fn addServiceSorted(self: *World, service: ServiceSpec) !void {
        // Find insertion position (sorted by service_id)
        var insert_pos: usize = 0;
        for (self.services[0..self.service_count]) |existing| {
            if (existing.service_id > service.service_id) break;
            insert_pos += 1;
        }

        // Shift existing entries
        var shift_pos = self.service_count;
        while (shift_pos > insert_pos) : (shift_pos -= 1) {
            const from_idx = shift_pos - 1;
            self.services[shift_pos] = self.services[from_idx];
            self.service_index[self.services[from_idx].service_id] = @truncate(shift_pos);
        }

        // Insert at position
        self.services[insert_pos] = service;
        self.indexService(service.service_id, insert_pos);
        self.service_count += 1;
    }

    /// Get service name by service index.
    pub fn getServiceName(self: *const World, name_index: u8) []const u8 {
        return self.name_table.get(name_index);
    }

    /// Add a name to the name table, return index.
    pub fn addServiceName(self: *World, name: []const u8) !u8 {
        return self.name_table.add(name);
    }

    /// Validate nodes have non-zero IDs.
    fn validateNodes(self: *const World) !void {
        for (self.nodes[0..self.node_count]) |node| {
            if (node.node_id == 0) {
                return error.InvalidNodeId;
            }
        }
    }

    /// Validate services have non-zero IDs and valid name indices.
    fn validateServices(self: *const World) !void {
        for (self.services[0..self.service_count]) |svc| {
            if (svc.service_id == 0) {
                return error.InvalidServiceId;
            }
            // Check for valid name index (must be within table)
            if (svc.name_index == 0 or svc.name_index > self.name_table.count()) {
                return error.InvalidServiceName;
            }
        }
    }

    /// Validate placements reference valid services and nodes.
    fn validatePlacements(self: *const World) !void {
        for (self.placements[0..self.placement_count]) |placement| {
            if (!placement.active) continue;
            if (placement.service_id == 0 or placement.node_id == 0) {
                return error.InvalidPlacement;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "World.init returns World with zero counts" {
    const world = World.init();

    try std.testing.expectEqual(@as(usize, 0), world.node_count);
    try std.testing.expectEqual(@as(usize, 0), world.node_meta_count);
    try std.testing.expectEqual(@as(usize, 0), world.node_health_count);
    try std.testing.expectEqual(@as(usize, 0), world.service_count);
    try std.testing.expectEqual(@as(usize, 0), world.service_runtime_count);
    try std.testing.expectEqual(@as(usize, 0), world.placement_count);
}

test "World.init has correct array sizes" {
    const world = World.init();

    try std.testing.expectEqual([limits.max_nodes]Node, @TypeOf(world.nodes));
    try std.testing.expectEqual([limits.max_nodes]NodeMeta, @TypeOf(world.node_metas));
    try std.testing.expectEqual([limits.max_nodes]NodeHealth, @TypeOf(world.node_health));
    try std.testing.expectEqual([limits.max_services]ServiceSpec, @TypeOf(world.services));
    try std.testing.expectEqual(
        [limits.max_services]ServiceRuntime,
        @TypeOf(world.service_runtimes),
    );
    try std.testing.expectEqual([limits.max_placements]ServicePlacement, @TypeOf(world.placements));
}

test "NodeHealthStatus enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(NodeHealthStatus.healthy));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(NodeHealthStatus.degraded));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(NodeHealthStatus.unhealthy));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(NodeHealthStatus.unknown));
}

test "NodeHealth default values" {
    const health = NodeHealth{ .node_id = 1 };

    try std.testing.expectEqual(@as(u16, 1), health.node_id);
    try std.testing.expectEqual(NodeHealthStatus.unknown, health.status);
    try std.testing.expectEqual(@as(u64, 0), health.last_heartbeat_ms);
    try std.testing.expectEqual(@as(u8, 0), health.health_check_failures);
}

test "NodeMeta default values" {
    const meta = NodeMeta{ .node_id = 1 };

    try std.testing.expectEqual(@as(u16, 1), meta.node_id);
    try std.testing.expectEqual(@as(u32, 0), meta.cpu_mhz);
    try std.testing.expectEqual(@as(u32, 0), meta.mem_free_mb);
    try std.testing.expectEqual(Platform.unknown, meta.platform);
    try std.testing.expectEqual(false, meta.active);
}

test "ServiceSpec default values" {
    const spec = ServiceSpec{ .service_id = 1, .name_index = 0, .replicas = 3 };

    try std.testing.expectEqual(@as(u16, 1), spec.service_id);
    try std.testing.expectEqual(@as(u8, 0), spec.name_index);
    try std.testing.expectEqual(@as(u8, 3), spec.replicas);
    try std.testing.expectEqual(@as(u64, 0), spec.spec_hash);
    try std.testing.expectEqual(@as(u16, 0), spec.platform_mask);
    try std.testing.expectEqual(false, spec.active);
}

test "ServiceRuntime default values" {
    const runtime = ServiceRuntime{ .service_id = 1 };

    try std.testing.expectEqual(@as(u16, 1), runtime.service_id);
    try std.testing.expectEqual(false, runtime.running);
    try std.testing.expectEqual(@as(u8, 0), runtime.last_exit_code);
    try std.testing.expectEqual(@as(u8, 0), runtime.backoff_level);
    try std.testing.expectEqual(false, runtime.active);
}

test "ServicePlacement default values" {
    const placement = ServicePlacement{ .service_id = 1, .replica_id = 0 };

    try std.testing.expectEqual(@as(u16, 1), placement.service_id);
    try std.testing.expectEqual(@as(u8, 0), placement.replica_id);
    try std.testing.expectEqual(@as(u16, 0), placement.node_id);
    try std.testing.expectEqual(@as(u32, 0), placement.lease_epoch);
    try std.testing.expectEqual(false, placement.active);
}

test "Platform enum values" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Platform.linux_x64));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Platform.linux_arm64));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Platform.unknown));
}

test "World.findNode returns null for missing node" {
    var world = World.init();

    const result = world.findNode(1);
    try std.testing.expectEqual(null, result);
}

test "World.findService returns null for missing service" {
    var world = World.init();

    const result = world.findService(1);
    try std.testing.expectEqual(null, result);
}

test "World.findPlacement returns null for missing placement" {
    var world = World.init();

    const result = world.findPlacement(1, 0);
    try std.testing.expectEqual(null, result);
}
