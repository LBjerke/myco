# Tech Debt: WAL Replay Error Handling

## Summary

Errors during WAL replay are logged as warnings but the system continues to start, potentially with an incomplete or inconsistent state.

## Problem Statement

In `src/main.zig`, after WAL replay completes, errors from the reducer are only printed as warnings:

```zig
// Lines 144-151: Example event application with error handling
const new_node_event = makeNodeJoinEvent(1, .{ 192, 168, 1, 100 }, 8080);
const result = reduce(&world, WalEvent.create(new_node_event).event);

if (result.err) |err| {
    std.debug.print("Warning: reduce error: {}\n", .{err});
} else {
    std.debug.print("Applied node_join event\n", .{});
    switch (result.effect) {
        // ... effect handling
    }
}
```

And in the reducer replay:

```zig
// Line 138: Replay just ignores errors
try wal.replay(&world, reduceReplay);
```

**Issues:**
1. **Silent failures** - Replay errors could be silently ignored
2. **Inconsistent state** - If replay fails partway, world state may be partial
3. **No recovery strategy** - System doesn't know if state is complete or corrupted
4. **No WAL corruption detection** - Checksum failures aren't clearly communicated to user

## Status

**Not Fixed** - This is a data integrity concern.

## Suggested Fix

### Option 1: Fail Fast on Replay Error (Recommended)

```zig
// In src/main.zig - During initWorld
var replay_errors: usize = 0;

// Modify reduceReplay to track errors
wal.replay(&world, reduceReplay) catch |err| {
    std.debug.print("FATAL: WAL replay failed: {}\n", .{err});
    return err;
};

// Verify expected state
if (replay_errors > 0) {
    std.debug.print("WARNING: {} events failed during replay\n", .{replay_errors});
    return error.WalReplayIncomplete;
}
```

### Option 2: Continue with Partial State (Explicit)

```zig
// Make it explicit that we're running with partial state
const initial_node_count = world.node_count;
const initial_service_count = world.service_count;

try wal.replay(&world, reduceReplay);

if (world.node_count < initial_node_count or 
    world.service_count < initial_service_count) {
    // State is incomplete - log clearly
    std.debug.print("WARNING: Running with partial state from WAL\n", .{});
    std.debug.print("  Nodes: expected {}, got {}\n", .{ 
        initial_node_count, world.node_count 
    });
}
```

### Option 3: Add Health Check

```zig
// After replay, verify world is in a valid state
pub fn validateWorld(world: *World) !void {
    // All active services should have valid IDs
    for (world.services[0..world.service_count]) |svc| {
        if (svc.service_id == 0) {
            return error.InvalidServiceId;
        }
    }
    
    // Nodes should be in valid range
    for (world.nodes[0..world.node_count]) |node| {
        if (node.id == 0) {
            return error.InvalidNodeId;
        }
    }
}

// In main.zig
try wal.replay(&world, reduceReplay);
try world.validateWorld();  // Verify state integrity
```

## Benefits

1. **Data integrity** - Fail fast rather than running with corrupted state
2. **Debuggability** - Clear error messages help diagnose issues
3. **Recovery path** - Explicit handling allows for recovery strategies
4. **User notification** - Users know if their cluster state is incomplete

## Related Files

- `src/main.zig` - Lines 138-151 (replay and event application)
- `src/db/wal.zig` - Lines 328-415 (replay implementation)
- `src/core/reducer.zig` - ReduceError enum

## Additional Considerations

- Consider adding a WAL manifest/tracking file that records which events were successfully applied
- Consider implementing WAL repair tools for corrupted segments
- Consider adding a checksum verification step after replay

## Priority

**Medium** - Important for production use but may be acceptable for development/testing

---

*Created: 2026-03-12*
*Status: Not Fixed*
