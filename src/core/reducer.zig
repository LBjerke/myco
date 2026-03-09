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
const Event = @import("event.zig").Event;

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
    name: []const u8,
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

/// Result of applying a reducer: new world state + list of effects.
pub const ReduceResult = struct {
    world: *World,
    effect: Effect,
    /// Error that occurred during reduction (null if none)
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
};

/// Apply an event to the world, producing effects.
///
/// This is the core reducer function. It:
/// 1. Updates the world state based on the event
/// 2. Returns effects that the shell should execute
/// 3. Never performs I/O - only describes what should happen
///
/// Note: This function modifies the world in place.
pub fn reduce(world: *World, event: Event) ReduceResult {
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
fn reduceInternal(world: *World, event: Event, comptime emit_effects: bool) struct { effect: Effect, err: ?ReduceError } {
    switch (event) {
        .node_join => |ev| {
            // Check if node already exists
            for (world.nodes[0..world.node_count]) |*node| {
                if (node.id == ev.node_id) {
                    // Node already exists - mark as alive
                    node.alive = true;
                    if (emit_effects) {
                        return .{ .effect = .none, .err = null };
                    }
                    return .{ .effect = undefined, .err = null }; // For replay, effect is ignored
                }
            }

            // Add new node
            if (world.node_count >= world.nodes.len) {
                if (emit_effects) {
                    return .{ .effect = .none, .err = error.NodeTableFull };
                }
                return .{ .effect = undefined, .err = error.NodeTableFull };
            }

            world.nodes[world.node_count] = .{
                .id = ev.node_id,
                .alive = true,
            };
            world.node_count += 1;

            if (emit_effects) {
                return .{ .effect = .{ .node_joined = NodeJoinedEffect{
                    .node_id = ev.node_id,
                    .address = ev.address,
                    .port = ev.port,
                } }, .err = null };
            }
            return .{ .effect = undefined, .err = null };
        },

        .node_leave => |ev| {
            // Mark node as not alive
            for (world.nodes[0..world.node_count]) |*node| {
                if (node.id == ev.node_id) {
                    node.alive = false;
                    if (emit_effects) {
                        return .{ .effect = .{ .node_left = NodeLeftEffect{ .node_id = ev.node_id } }, .err = null };
                    }
                    return .{ .effect = undefined, .err = null };
                }
            }
            // Node not found - ignore
            if (emit_effects) {
                return .{ .effect = .none, .err = null };
            }
            return .{ .effect = undefined, .err = null };
        },

        .service_deploy => |ev| {
            // Check if service already exists
            for (world.services[0..world.service_count]) |svc| {
                if (svc.service_id == ev.service_id) {
                    // Update existing service
                    if (emit_effects) {
                        return .{ .effect = .none, .err = null };
                    }
                    return .{ .effect = undefined, .err = null };
                }
            }

            // Add new service
            if (world.service_count >= world.services.len) {
                if (emit_effects) {
                    return .{ .effect = .none, .err = error.ServiceTableFull };
                }
                return .{ .effect = undefined, .err = error.ServiceTableFull };
            }

            world.services[world.service_count] = .{
                .service_id = ev.service_id,
                .name = ev.getName(),
                .replicas = ev.replicas,
                .active = true,
            };
            world.service_count += 1;

            if (emit_effects) {
                return .{ .effect = .{ .service_deployed = ServiceDeployedEffect{
                    .service_id = ev.service_id,
                    .name = ev.getName(),
                    .replicas = ev.replicas,
                } }, .err = null };
            }
            return .{ .effect = undefined, .err = null };
        },

        .service_remove => |ev| {
            // Remove service by shifting remaining services
            var found = false;
            var i: usize = 0;
            while (i < world.service_count) : (i += 1) {
                if (world.services[i].service_id == ev.service_id) {
                    found = true;
                    // Shift remaining services
                    while (i < world.service_count - 1) {
                        world.services[i] = world.services[i + 1];
                        i += 1;
                    }
                    world.service_count -= 1;
                    break;
                }
            }

            if (found) {
                if (emit_effects) {
                    return .{ .effect = .{ .service_removed = ServiceRemovedEffect{ .service_id = ev.service_id } }, .err = null };
                }
                return .{ .effect = undefined, .err = null };
            }
            if (emit_effects) {
                return .{ .effect = .none, .err = null };
            }
            return .{ .effect = undefined, .err = null };
        },

        .health_status_change => |ev| {
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
        },
    }
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
    try testing.expectEqual(@as(u16, 1), world.nodes[0].id);
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
    var world = World.init();

    var event = Event{
        .service_deploy = ServiceDeployEvent{
            .service_id = 1,
            .name = undefined,
            .name_len = 10,
            .replicas = 3,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };
    @memcpy(event.service_deploy.name[0..10], "my-service");

    const result = reduce(&world, event);

    try testing.expectEqual(@as(?ReduceError, null), result.err);
    try testing.expectEqual(@as(usize, 1), world.service_count);
    try testing.expectEqualStrings("my-service", world.services[0].name);
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
    try testing.expectEqual(@import("../ecs/world.zig").NodeHealthStatus.healthy, world.node_health[0].status);
}

test "reduce: full node table returns error" {
    var world = World.init();

    // Fill the node table
    for (0..world.nodes.len) |i| {
        world.nodes[i] = .{ .id = @truncate(i), .alive = true };
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
