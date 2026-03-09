# Feature: Node Health ECS Component

## Status: ✅ Complete

## Original Ask

Create a new ECS component for node health to track the health status, last heartbeat, and health metrics for each node in the cluster.

## Where Code Was Added/Changed

### Files Modified

| File | Changes |
|------|---------|
| `src/ecs/world.zig` | Added NodeHealth component, NodeHealthStatus enum, and integrated into World struct |

### Code Added

#### NodeHealthStatus enum
```zig
/// Node health status enum.
pub const NodeHealthStatus = enum(u8) {
    healthy = 0,
    degraded = 1,
    unhealthy = 2,
    unknown = 3,
};
```

#### NodeHealth component
```zig
/// Node health component - tracks health state and heartbeat.
pub const NodeHealth = struct {
    node_id: u16,
    status: NodeHealthStatus = .unknown,
    last_heartbeat_ms: u64 = 0,
    health_check_failures: u8 = 0,
};
```

#### World integration
```zig
/// The ECS World - holds all component tables.
pub const World = struct {
    /// Nodes in the cluster.
    nodes: [limits.MAX_NODES]Node,
    node_count: usize = 0,

    /// Node health components.
    node_health: [limits.MAX_NODES]NodeHealth,
    node_health_count: usize = 0,

    /// Service specifications.
    services: [limits.MAX_SERVICES]ServiceSpec,
    service_count: usize = 0,
    ...
};
```

## Architecture

```
┌─────────────────────────────────────┐
│           ECS World                 │
├─────────────────────────────────────┤
│  Node[]          ServiceSpec[]      │
│  [id, alive]     [id, name, replicas]│
│                                     │
│  NodeHealth[]                        │
│  [node_id, status, last_heartbeat, │
│   health_check_failures]            │
│                                     │
│  Fixed-capacity tables (SoA)        │
└─────────────────────────────────────┘
```

### Component Fields

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | u16 | Reference to the node |
| `status` | NodeHealthStatus | Current health status (healthy/degraded/unhealthy/unknown) |
| `last_heartbeat_ms` | u64 | Timestamp of last heartbeat |
| `health_check_failures` | u8 | Count of consecutive health check failures |

### NodeHealthStatus Values

| Status | Value | Meaning |
|--------|-------|---------|
| `healthy` | 0 | Node is fully operational |
| `degraded` | 1 | Node is operating with issues |
| `unhealthy` | 2 | Node is not responding properly |
| `unknown` | 3 | Health status not yet determined |

## Testing

### Tests Added

```zig
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
```

### Test Results

```
All 9 tests passed:
- limits.zig:  5/5 ✓
- hlc.zig:     6/6 ✓
- world.zig:   6/6 ✓ (including new NodeHealth tests)
```

## Summary

Added NodeHealth ECS component to the ECS world:
- **NodeHealthStatus** enum with 4 states (healthy, degraded, unhealthy, unknown)
- **NodeHealth** component struct with node_id, status, last_heartbeat_ms, and health_check_failures
- Integrated into World struct with fixed-capacity array bounded by MAX_NODES (64)
- Follows existing ECS pattern: fixed-capacity arrays, columnar storage, bounded limits
- All tests pass via `zig build test`
