# Feature: Simulation Harness & Property-Based Testing

**Status**: ✅ Complete

## Original Ask

Add comprehensive simulation scenarios and property-based tests to enable thorough testing of cluster behavior without requiring a real distributed system.

## Why This Matters

Traditional E2E testing doesn't apply to a daemon like Myco (no HTTP API, no CLI yet). The simulation harness provides:

- **Fast feedback** - Tests run in milliseconds, not seconds
- **Deterministic behavior** - Reproducible test scenarios
- **Edge case coverage** - Property-based testing finds bugs in corner cases
- **No infrastructure** - No need to spin up multiple nodes/machines

## Where Code Was Added/Changed

| File | Action | Description |
|------|--------|-------------|
| `tests/simulation.zig` | Modified | Added 6 new scenarios + 6 property tests |

## New Simulation Scenarios

| Scenario | Description | Test Name |
|----------|-------------|------------|
| `concurrent_node_joins` | 5 nodes join simultaneously | `Simulation: concurrent_node_joins scenario` |
| `rapid_health_changes` | Health oscillates 6 times | `Simulation: rapid_health_changes scenario` |
| `service_redeploy` | Deploy same service twice | `Simulation: service_redeploy scenario` |
| `node_flapping` | Node join/leave/rejoin cycle | `Simulation: node_flapping scenario` |
| `max_nodes` | 10 nodes join in sequence | `Simulation: max_nodes scenario` |
| `wal_replay` | Deploy 2 services, remove 1 | `Simulation: wal_replay scenario` |

### Example: Concurrent Node Joins

```zig
pub fn scenarioConcurrentNodeJoins() Scenario {
    return Scenario{
        .name = "concurrent_node_joins",
        .description = "Multiple nodes join at the same time",
        .steps = &.{
            .{ .advance_time = 100 },
            .{ .node_join = .{ .node_id = 1, .address = .{ 192, 168, 1, 10 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 2, .address = .{ 192, 168, 1, 11 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 3, .address = .{ 192, 168, 1, 12 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 4, .address = .{ 192, 168, 1, 13 }, .port = 8080 } },
            .{ .node_join = .{ .node_id = 5, .address = .{ 192, 168, 1, 14 }, .port = 8080 } },
            .{
                .verify = .{
                    .description = "All 5 nodes should be present",
                    .expected_nodes = 5,
                    .expected_services = 0,
                    .check_fn = &(struct {
                        fn check(w: *const World) bool {
                            return w.node_count == 5;
                        }
                    }).check,
                },
            },
        },
    };
}
```

## Property-Based Tests

Property-based testing runs operations many times with varying inputs to find edge cases:

| Test | Property Verified |
|------|-------------------|
| `property: node_join idempotent` | Adding same node 10 times = exactly 1 node |
| `property: service_deploy idempotent` | Deploying same service 10 times = exactly 1 service |
| `property: health_oscillation converges` | Rapid health changes converge to final state |
| `property: random_operations consistent` | 100 varied operations stay within bounds |
| `property: node_leave_then_join` | Node can leave and rejoin correctly |
| `property: service_deploy_remove_deploy` | Deploy→remove→deploy produces correct final state |

### Example: Idempotency Property

```zig
test "property: node_join idempotent" {
    var sim = Simulation.init(.{});

    const event = Event{
        .node_join = .{
            .node_id = 1,
            .address = .{ 192, 168, 1, 10 },
            .port = 8080,
            .timestamp = .{ .time = 1000, .count = 1, .node_id = 0 },
        },
    };

    // Apply same event multiple times
    for (0..10) |_| {
        const result = reducer.reduce(&sim.world, event);
        try testing.expect(result.err == null);
    }

    // Should only have 1 node (idempotent!)
    try testing.expectEqual(@as(usize, 1), sim.world.node_count);
}
```

## Test Execution

```bash
# Run all unit tests
zig build test

# Run simulation tests
zig build test-sim
```

## Test Results

```
zig build test    # 10/10 unit tests pass
zig build test-sim # 19/19 simulation tests pass
```

## Architecture: Simulation Harness

```
Simulation
├── World          # ECS state (nodes, services, health)
├── Clock          # HLC timestamp for ordering
├── Network        # NetworkSimulator (latency, packet loss)
└── Scenarios     # Test scenarios with steps
```

### Step Types

| Step | Description |
|------|-------------|
| `advance_time` | Fast-forward simulation time |
| `node_join` | Add node to cluster |
| `node_leave` | Remove node from cluster |
| `service_deploy` | Deploy a service |
| `service_remove` | Remove a service |
| `health_change` | Update node health status |
| `verify` | Assert expected state |

## Future Enhancements

When Phase 3 (CLI & API) arrives, consider:

1. **System-level E2E tests** - Spawn binary, test CLI commands
2. **HTTP API tests** - Use k6 or curl for API testing
3. **Property-based fuzzing** - Random event sequences to find bugs
4. **Performance benchmarks** - Measure tick latency under load

## Summary

Added comprehensive testing capabilities:

1. **6 new simulation scenarios** covering:
   - Concurrent operations
   - Health monitoring edge cases
   - Service idempotency
   - Node flapping behavior
   - Multi-node scaling
   - WAL replay simulation

2. **6 property-based tests** verifying:
   - Idempotency of operations
   - State convergence
   - Invariant preservation
   - Edge case handling

All tests pass. The simulation harness is now ready for testing cluster behavior during the networking phase.
