# Feature: Reducer Protocol

**Status**: ✅ Complete

## Original Ask

Implement a formal reducer protocol for applying events to state, following the functional core pattern described in the proposal.

## Why This Matters

The original code in main.zig had inline event application logic:
```zig
try wal.replay(&world, struct {
    fn apply(w: *World, e: wal_mod.Event) void {
        switch (e) {
            .node_join => |ev| { ... },
            .service_deploy => |ev| { ... },
            else => {},
        }
    }
}.apply);
```

This approach has problems:
- **Not testable** - can't test event application without the full WAL
- **Mixed concerns** - event logic is embedded in the replay callback
- **No effects** - no way to express side effects that should happen after state changes

The reducer pattern solves this by:
1. **Separating state from effects** - reducers return both new state AND effects
2. **Making logic explicit** - all event handling is in one place
3. **Enabling testing** - test reducers without network or filesystem

## Where Code Was Added/Changed

| File | Action | Description |
|------|--------|-------------|
| `src/core/reducer.zig` | Created | Formal reducer module with effects system |
| `src/main.zig` | Modified | Use new reducer instead of inline code |
| `src/util/allocator.zig` | Modified | Increased buffer size to 128KB |
| `src/db/wal.zig` | Modified | Made WalEvent public |
| `src/core/event.zig` | Modified | Fixed checksum calculation bug |

## Architecture

```
Reducer Pattern:
+------------------+     +---------------+     +------------------+
|     Event        |---->|   Reducer     |---->|     Effect      |
| (input: node_join|     | (world, event)|     | (gossip,systemd)|
|  service_deploy) |     |  + world'     |     |  + world'       |
+------------------+     +---------------+     +------------------+

Effect Types:
- node_joined    -> gossip to peers, start systemd service
- node_left      -> gossip to peers, cleanup
- service_deployed -> start systemd units
- service_removed  -> stop systemd units  
- health_changed  -> update monitoring
- none            -> no side effects needed
```

### Key Components

1. **Effect union** (`reducer.zig:20-38`)
   - Defines all possible side effects
   - Never performs I/O - just describes what should happen

2. **reduce() function** (`reducer.zig:100-107`)
   - Main reducer entry point
   - Returns new world + effect + optional error

3. **reduceReplay() function** (`reducer.zig:253-323`)
   - Used for WAL replay
   - Applies events WITHOUT producing effects

## Testing

Added comprehensive tests in reducer.zig:
- `test "reduce: node_join adds node to world"`
- `test "reduce: duplicate node_join is idempotent"`
- `test "reduce: node_leave marks node as not alive"`
- `test "reduce: service_deploy adds service"`
- `test "reduce: service_remove removes service"`
- `test "reduce: health_status_change updates health"`
- `test "reduce: full node table returns error"`
- `test "reduceReplay: applies events without effects"`

All tests pass:
```
zig build test
```

## Usage in main.zig

```zig
// Apply event using reducer
const result = reduce(&world, WalEvent.create(new_node_event).event);

if (result.err) |err| {
    std.debug.print("Warning: reduce error: {}\n", .{err});
} else {
    // Handle effect - this is what the imperative shell does
    switch (result.effect) {
        .node_joined => |e| {
            // TODO: gossip to peers
            // TODO: start systemd service
        },
        // ...
    }
}
```

## Summary

The reducer protocol is now implemented:

1. **Formal reducer module** - All event handling in one place
2. **Effects system** - Side effects are explicit and testable
3. **Replay support** - WAL replay uses same logic without effects
4. **Error handling** - Table-full and other errors handled gracefully
5. **Comprehensive tests** - 8 tests covering all event types

This enables:
- Testable state logic (no I/O dependencies)
- Clear separation of concerns (reducer vs shell)
- Consistent event handling (same code for replay and live events)
- Future extensibility (add new effects easily)
