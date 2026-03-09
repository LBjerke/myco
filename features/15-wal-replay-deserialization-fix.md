# Feature: WAL Replay Deserialization Fix

**Status**: ✅ Complete

## Original Ask

Fix the WAL replay functionality in `src/db/wal.zig` - the replay() function was not actually deserializing events from disk, instead it was creating placeholder node_join events and ignoring the actual stored data. This made WAL replay completely non-functional.

## Why This Matters

The WAL is a core durability feature. Without proper replay:
- The system cannot recover state after restart
- All persisted events are effectively lost on restart
- The "durability" guarantee is broken

## Problem Identified

In `src/db/wal.zig`, the replay() function (lines 361-398) was:
1. Reading the event type from the buffer to advance position correctly
2. Skipping the correct number of bytes based on event type
3. But then ignoring all the actual event data
4. Creating a dummy `makeNodeJoinEvent(0, .{ 0, 0, 0, 0 }, 0)` for every event

This meant that even though events were written correctly to WAL, they were never properly reconstructed during replay.

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `src/db/wal.zig` | Modified | Replaced placeholder creation with proper deserialization |
| `src/core/event.zig` | Modified | Fixed broken deserialize methods |

### Implementation Details

In `wal.zig`, replaced the placeholder event creation with:
```zig
// Create a reader from the current position
const event_buffer = buffer[pos..];
var fbs = std.io.fixedBufferStream(event_buffer);

// Deserialize the event (this reads the type byte and all event data)
const deserialized_event = Event.deserialize(fbs.reader()) catch {
    // If deserialization fails, skip to next event based on type
    // This handles malformed data gracefully
    // ...
};

// Advance position by the bytes consumed
pos += fbs.pos;

// Pass the properly deserialized event to applyFn
applyFn(ctx, deserialized_event);
```

In `event.zig`, discovered and fixed multiple issues with the deserialize methods:
1. `reader.readByte(EventType)` was incorrect syntax - fixed to use `@enumFromInt`
2. `reader.readIntLittle()` and `reader.readBytes()` don't exist on GenericReader - created helper functions:
   - `readU16()` - reads 2 bytes and converts to u16
   - `readU64()` - reads 8 bytes and converts to u64  
   - `readBytes()` - reads N bytes into array

## Testing

All tests pass:
```
zig build test
# Exit code: 0
```

The WAL replay now correctly:
1. Reads events from disk
2. Deserializes them into proper Event types
3. Passes the correct event data to the applyFn callback

## Learnings & Troubleshooting

### Issue Discovered: Zig 0.15 Reader API Changes
The original deserialize methods used `reader.readIntLittle()` and `reader.readBytes()` which don't exist on `GenericReader` in Zig 0.15. These methods are only available on the `Reader` type that wraps a stream.

**Solution**: Created helper functions that use `reader.readNoEof()` to read raw bytes, then manually convert them to the appropriate integer types.

### Event Serialization Format
Understanding the exact serialization format was crucial:
- NodeJoinEvent: type(1) + node_id(2) + address(4) + port(2) + timestamp(14) = 23 bytes
- ServiceDeployEvent: type(1) + service_id(2) + name(32) + name_len(1) + replicas(1) + timestamp(14) = 51 bytes

The Event.deserialize() function reads the type byte itself, so the buffer position needs to be set to the start of the event data (after advancing past the type byte that was already read).

### Error Handling
Added graceful error handling in replay - if deserialization fails for an event, it skips to the next event rather than failing the entire replay. This provides resilience against corrupted WAL data.

## Related Issues

- Issue #003: WAL Uses Page Allocator After Freeze (also fixed during this work)
