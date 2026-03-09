# Issue: WAL Replay Does Not Deserialize Events

## Summary
The WAL replay functionality does not actually deserialize events from disk - it creates a placeholder event and ignores the actual stored data. This makes WAL replay completely non-functional.

## Severity
**CRITICAL** - The WAL is a core durability feature. Without proper replay, the system cannot recover state after restart.

## Location
- File: `src/db/wal.zig`
- Function: `replay()` (lines 305-400)
- Specific issue: Lines 394-397

## Current Behavior
```zig
// Current code just skips through the buffer and calls applyFn with placeholder
const placeholder_event = makeNodeJoinEvent(0, .{ 0, 0, 0, 0 }, 0);
applyFn(ctx, placeholder_event);
```

The code parses the event type from the buffer to advance the position correctly, but then throws away the actual event data and always passes a dummy node_join event.

## Expected Behavior
Each event should be fully deserialized and passed to the applyFn callback.

## How to Fix
1. After reading each event's type and advancing position, actually deserialize the event using `Event.deserialize()`
2. Pass the deserialized event to `applyFn`
3. Consider creating a helper function that reads events from a buffer stream

## Relevant Code
- `src/core/event.zig` - Event types with `serialize()` and `deserialize()` methods
- `src/core/reducer.zig` - `reduceReplay()` function that uses the applyFn
- The event sizes in the switch statement (lines 369-390) give hints about serialization format

## Event Serialization Format
From `src/core/event.zig`:
- NodeJoinEvent: node_id(2) + address(4) + port(2) + timestamp(12) = 20 bytes + 1 byte type = 21
- NodeLeaveEvent: node_id(2) + timestamp(12) = 14 bytes + 1 byte type = 15
- ServiceDeployEvent: service_id(2) + name(32) + name_len(1) + replicas(1) + timestamp(12) = 48 bytes + 1 byte type = 49
- ServiceRemoveEvent: service_id(2) + timestamp(12) = 14 bytes + 1 byte type = 15
- HealthStatusChangeEvent: node_id(2) + new_status(1) + timestamp(12) = 15 bytes + 1 byte type = 16

## Testing Approach
1. Write events to WAL
2. Create new World instance
3. Replay WAL into new World
4. Verify World state matches expected state from original events

## Related Issues
- Issue: #002 - WAL uses page allocator after freeze
