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
const Timestamp = hlc.Timestamp;

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
    id: u16,
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
pub const ServiceSpec = struct {
    service_id: u16,
    name: []const u8,
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
    nodes: [limits.MAX_NODES]Node,
    node_count: usize = 0,

    /// Node metadata (replicated).
    node_metas: [limits.MAX_NODES]NodeMeta,
    node_meta_count: usize = 0,

    /// Node health (local only).
    node_health: [limits.MAX_NODES]NodeHealth,
    node_health_count: usize = 0,

    // -------------------------------------------------------------------------
    // Service components
    // -------------------------------------------------------------------------

    /// Service specifications (replicated).
    services: [limits.MAX_SERVICES]ServiceSpec,
    service_count: usize = 0,

    /// Service runtime (local only).
    service_runtimes: [limits.MAX_SERVICES]ServiceRuntime,
    service_runtime_count: usize = 0,

    /// Service placements (replicated).
    placements: [limits.MAX_PLACEMENTS]ServicePlacement,
    placement_count: usize = 0,

    /// Initialize a new empty World.
    ///
    /// Note: Arrays are initialized with `undefined` for performance reasons.
    /// This is safe because:
    /// 1. All count fields are explicitly set to 0
    /// 2. Code only accesses indices 0..count
    /// 3. The unused slots never need to be read
    pub fn init() World {
        return World{
            // Node components - using undefined is safe: only 0..node_count is accessed
            .nodes = undefined,
            .node_count = 0,
            .node_metas = undefined,
            .node_meta_count = 0,
            .node_health = undefined,
            .node_health_count = 0,

            // Service components - using undefined is safe: only 0..service_count is accessed
            .services = undefined,
            .service_count = 0,
            .service_runtimes = undefined,
            .service_runtime_count = 0,
            .placements = undefined,
            .placement_count = 0,
        };
    }

    // -------------------------------------------------------------------------
    // Helper methods for finding components
    // -------------------------------------------------------------------------

    /// Find a node by ID.
    pub fn findNode(self: *const World, node_id: u16) ?*const Node {
        for (self.nodes[0..self.node_count]) |*node| {
            if (node.id == node_id) return node;
        }
        return null;
    }

    /// Find node metadata by ID.
    pub fn findNodeMeta(self: *const World, node_id: u16) ?*const NodeMeta {
        for (self.node_metas[0..self.node_meta_count]) |*meta| {
            if (meta.node_id == node_id and meta.active) return meta;
        }
        return null;
    }

    /// Find service by ID.
    pub fn findService(self: *const World, service_id: u16) ?*const ServiceSpec {
        for (self.services[0..self.service_count]) |*svc| {
            if (svc.service_id == service_id and svc.active) return svc;
        }
        return null;
    }

    /// Find placement by service + replica.
    pub fn findPlacement(self: *const World, service_id: u16, replica_id: u8) ?*const ServicePlacement {
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
        var result: [limits.MAX_REPLICAS_PER_SERVICE]ServicePlacement = undefined;
        var count: usize = 0;

        for (self.placements[0..self.placement_count]) |*placement| {
            if (placement.service_id == service_id and placement.active) {
                if (count < limits.MAX_REPLICAS_PER_SERVICE) {
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
        // Validate nodes have non-zero IDs
        for (self.nodes[0..self.node_count]) |node| {
            if (node.id == 0) {
                return error.InvalidNodeId;
            }
        }

        // Validate services have non-zero IDs and valid names
        for (self.services[0..self.service_count]) |svc| {
            if (svc.service_id == 0) {
                return error.InvalidServiceId;
            }
            // Check for valid name (non-empty, within bounds)
            if (svc.name.len == 0 or svc.name.len > svc.name.len) {
                return error.InvalidServiceName;
            }
        }

        // Validate placements reference valid services and nodes
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

    try std.testing.expectEqual([limits.MAX_NODES]Node, @TypeOf(world.nodes));
    try std.testing.expectEqual([limits.MAX_NODES]NodeMeta, @TypeOf(world.node_metas));
    try std.testing.expectEqual([limits.MAX_NODES]NodeHealth, @TypeOf(world.node_health));
    try std.testing.expectEqual([limits.MAX_SERVICES]ServiceSpec, @TypeOf(world.services));
    try std.testing.expectEqual([limits.MAX_SERVICES]ServiceRuntime, @TypeOf(world.service_runtimes));
    try std.testing.expectEqual([limits.MAX_PLACEMENTS]ServicePlacement, @TypeOf(world.placements));
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
    const spec = ServiceSpec{ .service_id = 1, .name = "test", .replicas = 3 };

    try std.testing.expectEqual(@as(u16, 1), spec.service_id);
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
