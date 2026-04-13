//! Reducer Protocol - Functional core for applying events to state.
//!
//! This module implements the "functional core" pattern where:
//! - Reducers take (world, event) and produce (world, effects)
//! - Reducers NEVER perform I/O - they only describe effects
//! - The imperative shell executes effects after the reducer runs
//!
//! This makes the system:
//! - Testable: test reducers without network or filesystem
//! - Deterministic: same input always produces same output
//! - Replayable: WAL replay uses the same reducers as live events

const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Node = @import("../ecs/world.zig").Node;
const ServiceSpec = @import("../ecs/world.zig").ServiceSpec;
const Event = @import("event.zig").Event;
const assert = @import("../util/assert.zig");

// ============================================================================
// Effect Types
// ============================================================================

/// Effects are side effects that happen AFTER state is updated.
/// The reducer produces these, and the imperative shell executes them.
/// This keeps I/O separate from state logic.
pub const Effect = union(enum) {
    /// A node joined the cluster - gossip this to peers.
    node_joined: NodeJoinedEffect,

    /// A node left the cluster - gossip this to peers.
    node_left: NodeLeftEffect,

    /// A service was deployed - prepare to start it.
    service_deployed: ServiceDeployedEffect,

    /// A service was removed - stop it.
    service_removed: ServiceRemovedEffect,

    /// Node health changed - update health monitoring.
    health_changed: HealthChangedEffect,

    /// No effect - event applied but no side effects needed.
    none: void,
};

/// Effect when a node joins.
pub const NodeJoinedEffect = struct {
    node_id: u16,
    address: [4]u8,
    port: u16,
};

/// Effect when a node leaves.
pub const NodeLeftEffect = struct {
    node_id: u16,
};

/// Effect when a service is deployed.
pub const ServiceDeployedEffect = struct {
    service_id: u16,
    name_index: u8,
    replicas: u8,
};

/// Effect when a service is removed.
pub const ServiceRemovedEffect = struct {
    service_id: u16,
};

/// Effect when node health changes.
pub const HealthChangedEffect = struct {
    node_id: u16,
    new_status: u8,
};

// ============================================================================
// Result Types
// ============================================================================

/// Result of applying a reducer: new world state + list of effects.
pub const ReduceResult = struct {
    world: *World,
    effect: Effect,
    /// Error that occurred during reduction (null if none)
    err: ?ReduceError,
};

/// Internal result type for reducer functions.
const InternalReduceResult = struct {
    effect: Effect,
    err: ?ReduceError,
};

/// Errors that can occur during reduction.
pub const ReduceError = error{
    /// Node table is full.
    NodeTableFull,
    /// Service table is full.
    ServiceTableFull,
    /// Node not found.
    NodeNotFound,
    /// Service not found.
    ServiceNotFound,
    /// Invalid event data.
    InvalidEvent,
    /// Service name too long.
    NameTooLong,
    /// Name table is full.
    NameTableFull,
};

// ============================================================================
// Public Reducer API
// ============================================================================

/// Apply an event to the world, producing effects.
///
/// This is the core reducer function. It:
/// 1. Updates the world state based on the event
/// 2. Returns effects that the shell should execute
/// 3. Never performs I/O - only describes what should happen
///
/// Note: This function modifies the world in place.
pub fn reduce(world: *World, event: Event) ReduceResult {
    // NASA Power of 10 Rule 5: Assert world state is valid
    assert.assert(
        world.node_count <= world.nodes.len,
        "World node_count exceeds array bounds",
    );
    assert.assert(
        world.service_count <= world.services.len,
        "World service_count exceeds array bounds",
    );

    const result = reduceInternal(world, event, true);
    return ReduceResult{
        .world = world,
        .effect = result.effect,
        .err = result.err,
    };
}

/// Apply an event during WAL replay (same as reduce but without effects).
///
/// This is used when replaying the WAL - we don't want to emit effects
/// because these events already happened in the past.
pub fn reduceReplay(world: *World, event: Event) void {
    _ = reduceInternal(world, event, false);
}

/// Internal reducer implementation.
/// Uses comptime flag to determine whether to emit effects.
fn reduceInternal(
    world: *World,
    event: Event,
    comptime emit_effects: bool,
) InternalReduceResult {
    // NASA Power of 10 Rule 5: Validate world state before processing any event
    assert.assert(
        world.node_count <= world.nodes.len,
        "Node count exceeds array bounds in reduceInternal",
    );
    assert.assert(
        world.service_count <= world.services.len,
        "Service count exceeds array bounds in reduceInternal",
    );

    switch (event) {
        .node_join => |ev| return reduceNodeJoin(world, ev, emit_effects),
        .node_leave => |ev| return reduceNodeLeave(world, ev, emit_effects),
        .service_deploy => |ev| return reduceServiceDeploy(world, ev, emit_effects),
        .service_remove => |ev| return reduceServiceRemove(world, ev, emit_effects),
        .health_status_change => |ev| return reduceHealthStatusChange(world, ev, emit_effects),
    }
}

// ============================================================================
// Event-Specific Reducers
// ============================================================================

/// Reduce a node_join event.
fn reduceNodeJoin(
    world: *World,
    ev: anytype,
    comptime emit_effects: bool,
) InternalReduceResult {
    // NASA Power of 10 Rule 5: Assert event data is valid
    assert.assert(ev.node_id != 0, "NodeJoinEvent node_id must not be zero");
    assert.assert(ev.port != 0, "NodeJoinEvent port must not be zero");

    // Check if node already exists using O(1) index lookup
    if (world.findNode(ev.node_id)) |_| {
        // Node already exists - mark as alive
        for (world.nodes[0..world.node_count]) |*node| {
            if (node.node_id == ev.node_id) {
                node.alive = true;
                break;
            }
        }
        if (emit_effects) {
            return .{ .effect = .none, .err = null };
        }
        return .{ .effect = undefined, .err = null };
    }

    // Add new node with sorted insertion
    if (world.node_count >= world.nodes.len) {
        if (emit_effects) {
            return .{ .effect = .none, .err = error.NodeTableFull };
        }
        return .{ .effect = undefined, .err = error.NodeTableFull };
    }

    const new_node = Node{ .node_id = ev.node_id, .alive = true };
    world.addNodeSorted(new_node) catch |err| {
        if (emit_effects) {
            return .{ .effect = .none, .err = err };
        }
        return .{ .effect = undefined, .err = err };
    };

    if (emit_effects) {
        return .{ .effect = .{ .node_joined = NodeJoinedEffect{
            .node_id = ev.node_id,
            .address = ev.address,
            .port = ev.port,
        } }, .err = null };
    }
    return .{ .effect = undefined, .err = null };
}

/// Reduce a node_leave event.
fn reduceNodeLeave(
    world: *World,
    ev: anytype,
    comptime emit_effects: bool,
) InternalReduceResult {
    // Check if node exists using O(1) index lookup
    if (world.findNode(ev.node_id)) |_| {
        // Mark node as not alive
        for (world.nodes[0..world.node_count]) |*node| {
            if (node.node_id == ev.node_id) {
                node.alive = false;
                break;
            }
        }
        // NOTE: Do NOT clear the index - node remains findable (as not alive)
        // This matches original behavior where node stays in array
        if (emit_effects) {
            const effect = NodeLeftEffect{ .node_id = ev.node_id };
            return .{ .effect = .{ .node_left = effect }, .err = null };
        }
        return .{ .effect = undefined, .err = null };
    }
    // Node not found - ignore
    if (emit_effects) {
        return .{ .effect = .none, .err = null };
    }
    return .{ .effect = undefined, .err = null };
}

/// Reduce a service_deploy event.
fn reduceServiceDeploy(
    world: *World,
    ev: anytype,
    comptime emit_effects: bool,
) InternalReduceResult {
    // NASA Power of 10 Rule 5: Assert event data is valid
    assert.assert(ev.service_id != 0, "ServiceDeployEvent service_id must not be zero");
    assert.assert(
        ev.name_len > 0 and ev.name_len <= 7,
        "ServiceDeployEvent name_len out of valid range (max 7 chars)",
    );
    assert.assert(
        ev.replicas > 0 and ev.replicas < 128,
        "ServiceDeployEvent replicas out of valid range",
    );

    // Check if service already exists using O(1) index lookup
    if (world.findService(ev.service_id)) |_| {
        // Update existing service
        if (emit_effects) {
            return .{ .effect = .none, .err = null };
        }
        return .{ .effect = undefined, .err = null };
    }

    // Add new service
    if (world.service_count >= world.services.len) {
        if (emit_effects) {
            return .{ .effect = .none, .err = error.ServiceTableFull };
        }
        return .{ .effect = undefined, .err = error.ServiceTableFull };
    }

    // Add name to name table and get index
    // IMPORTANT: Copy the name to our own buffer because ev.getName() points to
    // stack memory in the event which becomes invalid after this function returns
    const service_name = ev.getName();

    // Create a local copy on our stack that will remain valid
    var name_copy: [7]u8 = undefined;
    @memcpy(name_copy[0..service_name.len], service_name);
    const name_slice = name_copy[0..service_name.len];

    const name_index = world.addServiceName(name_slice) catch |err| {
        if (emit_effects) {
            return .{ .effect = .none, .err = err };
        }
        return .{ .effect = undefined, .err = err };
    };

    // Add new service with sorted insertion
    const new_service = ServiceSpec{
        .service_id = ev.service_id,
        .name_index = name_index,
        .replicas = ev.replicas,
        .active = true,
    };
    world.addServiceSorted(new_service) catch |err| {
        if (emit_effects) {
            return .{ .effect = .none, .err = err };
        }
        return .{ .effect = undefined, .err = err };
    };

    if (emit_effects) {
        return .{ .effect = .{ .service_deployed = ServiceDeployedEffect{
            .service_id = ev.service_id,
            .name_index = name_index,
            .replicas = ev.replicas,
        } }, .err = null };
    }
    return .{ .effect = undefined, .err = null };
}

/// Reduce a service_remove event.
fn reduceServiceRemove(
    world: *World,
    ev: anytype,
    comptime emit_effects: bool,
) InternalReduceResult {
    // Check if service exists using O(1) index lookup
    if (world.findService(ev.service_id)) |_| {
        // Find index by linear scan (needed for shifting)
        var found_index: usize = 0;
        for (world.services[0..world.service_count], 0..) |svc, idx| {
            if (svc.service_id == ev.service_id) {
                found_index = idx;
                break;
            }
        }

        // Shift remaining services
        var i = found_index;
        while (i < world.service_count - 1) : (i += 1) {
            world.services[i] = world.services[i + 1];
            // Update index for shifted service
            const shifted_id = world.services[i].service_id;
            world.indexService(shifted_id, i);
        }
        world.service_count -= 1;

        // Clear the index for removed service
        world.unindexService(ev.service_id);

        if (emit_effects) {
            const effect = ServiceRemovedEffect{ .service_id = ev.service_id };
            return .{ .effect = .{ .service_removed = effect }, .err = null };
        }
        return .{ .effect = undefined, .err = null };
    }
    if (emit_effects) {
        return .{ .effect = .none, .err = null };
    }
    return .{ .effect = undefined, .err = null };
}

/// Reduce a health_status_change event.
fn reduceHealthStatusChange(
    world: *World,
    ev: anytype,
    comptime emit_effects: bool,
) InternalReduceResult {
    // NASA Power of 10 Rule 5: Assert event data is valid
    assert.assert(ev.node_id != 0, "HealthStatusChangeEvent node_id must not be zero");
    assert.assert(ev.new_status < 4, "HealthStatusChangeEvent status out of valid range");

    // Find or add node health
    var health_idx: ?usize = null;
    for (world.node_health[0..world.node_health_count], 0..) |h, idx| {
        if (h.node_id == ev.node_id) {
            health_idx = idx;
            break;
        }
    }

    if (health_idx) |idx| {
        // Update existing health
        world.node_health[idx].status = @enumFromInt(ev.new_status);
        world.node_health[idx].last_heartbeat_ms = ev.timestamp.time;
    } else {
        // Add new health entry
        if (world.node_health_count < world.node_health.len) {
            world.node_health[world.node_health_count] = .{
                .node_id = ev.node_id,
                .status = @enumFromInt(ev.new_status),
                .last_heartbeat_ms = ev.timestamp.time,
                .health_check_failures = 0,
            };
            world.node_health_count += 1;
        }
    }

    if (emit_effects) {
        return .{ .effect = .{ .health_changed = HealthChangedEffect{
            .node_id = ev.node_id,
            .new_status = ev.new_status,
        } }, .err = null };
    }
    return .{ .effect = undefined, .err = null };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const event_mod = @import("event.zig");
const NodeJoinEvent = event_mod.NodeJoinEvent;
const ServiceDeployEvent = event_mod.ServiceDeployEvent;
const NodeLeaveEvent = event_mod.NodeLeaveEvent;
const ServiceRemoveEvent = event_mod.ServiceRemoveEvent;
const HealthStatusChangeEvent = event_mod.HealthStatusChangeEvent;
const Timestamp = @import("../net/hlc.zig").Timestamp;
const NameTable = @import("../net/name_table.zig").NameTable;

test "reduce: node_join adds node to world" {
    var world = World.init();

    const event = Event{
        .node_join = NodeJoinEvent{
            .node_id = 1,
            .address = .{ 192, 168, 1, 100 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    const result = reduce(&world, event);

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expectEqual(@as(usize, 1), world.node_count);
    try testing.expectEqual(@as(u16, 1), world.nodes[0].node_id);
    try testing.expect(world.nodes[0].alive);

    // Should have effect
    try testing.expect(result.effect == .node_joined);
}

test "reduce: duplicate node_join is idempotent" {
    var world = World.init();

    const event = Event{
        .node_join = NodeJoinEvent{
            .node_id = 1,
            .address = .{ 192, 168, 1, 100 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    // Apply twice
    _ = reduce(&world, event);
    _ = reduce(&world, event);

    try testing.expectEqual(@as(usize, 1), world.node_count);
}

test "reduce: node_leave marks node as not alive" {
    var world = World.init();

    // Add a node first
    _ = reduce(&world, Event{ .node_join = NodeJoinEvent{
        .node_id = 1,
        .address = .{ 192, 168, 1, 100 },
        .port = 8080,
        .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
    } });

    // Then remove it
    const result = reduce(&world, Event{ .node_leave = NodeLeaveEvent{
        .node_id = 1,
        .timestamp = .{ .time = 2000, .count = 2, .node_id = 0 },
    } });

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expect(!world.nodes[0].alive);
    try testing.expect(result.effect == .node_left);
}

test "reduce: service_deploy adds service" {
    // Create fresh world for this test
    var world = World.init();

    // Add name to world name table
    const name_idx1 = try world.addServiceName("test");
    try testing.expectEqualStrings("test", world.getServiceName(name_idx1));

    // Test the reduce flow
    var event = Event{
        .service_deploy = ServiceDeployEvent{
            .service_id = 1,
            .name = std.mem.zeroes([32]u8),
            .name_len = 4,
            .replicas = 3,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };
    @memcpy(event.service_deploy.name[0..4], "test");

    const result = reduce(&world, event);

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expectEqual(@as(usize, 1), world.service_count);
    try testing.expectEqualStrings("test", world.getServiceName(world.services[0].name_index));
    try testing.expectEqual(@as(u8, 3), world.services[0].replicas);
    try testing.expect(result.effect == .service_deployed);
}

test "reduce: service_remove removes service" {
    var world = World.init();

    // Add service
    var add_event = Event{
        .service_deploy = ServiceDeployEvent{
            .service_id = 1,
            .name = undefined,
            .name_len = 5,
            .replicas = 2,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };
    @memcpy(add_event.service_deploy.name[0..5], "mysvc");
    _ = reduce(&world, add_event);

    // Remove service
    const result = reduce(&world, Event{ .service_remove = ServiceRemoveEvent{
        .service_id = 1,
        .timestamp = .{ .time = 2000, .count = 2, .node_id = 0 },
    } });

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expectEqual(@as(usize, 0), world.service_count);
    try testing.expect(result.effect == .service_removed);
}

test "reduce: health_status_change updates health" {
    var world = World.init();

    const event = Event{
        .health_status_change = HealthStatusChangeEvent{
            .node_id = 1,
            .new_status = 0, // healthy
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    const result = reduce(&world, event);

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expectEqual(@as(usize, 1), world.node_health_count);
    try testing.expectEqual(@as(u16, 1), world.node_health[0].node_id);
    const expected_status = @import("../ecs/world.zig").NodeHealthStatus.healthy;
    try testing.expectEqual(expected_status, world.node_health[0].status);
}

test "reduce: full node table returns error" {
    var world = World.init();

    // Fill the node table
    for (0..world.nodes.len) |i| {
        world.nodes[i] = .{ .node_id = @truncate(i), .alive = true };
    }
    world.node_count = world.nodes.len;

    const event = Event{
        .node_join = NodeJoinEvent{
            .node_id = 999,
            .address = .{ 192, 168, 1, 100 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    const result = reduce(&world, event);

    try testing.expectEqual(@as(?ReduceError, error.NodeTableFull), result.err);
}

test "reduceReplay: applies events without effects" {
    var world = World.init();

    const event = Event{
        .node_join = NodeJoinEvent{
            .node_id = 1,
            .address = .{ 192, 168, 1, 100 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    reduceReplay(&world, event);

    try testing.expectEqual(@as(usize, 1), world.node_count);
}
