# Tech Debt: Event Reading Could Use Std Library

## Summary

The event serialization code in `event.zig` uses manual byte manipulation for reading integers that could be simplified using Zig's standard library functions.

## Problem Statement

In `src/core/event.zig`, there are custom helper functions for reading integers:

```zig
// Lines 9-13: Manual u16 reading
fn readU16(reader: anytype) !u16 {
    var bytes: [2]u8 = undefined;
    try reader.readNoEof(&bytes);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

// Lines 16-24: Manual u64 reading
fn readU64(reader: anytype) !u64 {
    var bytes: [8]u8 = undefined;
    try reader.readNoEof(&bytes);
    var result: u64 = 0;
    for (0..bytes.len) |i| {
        result |= @as(u64, bytes[i]) << @as(u6, @intCast(i * 8));
    }
    return result;
}
```

**Issues:**
1. **Redundant code** - Zig's std library already provides `reader.readInt()`
2. **Manual byte manipulation** - more error-prone than std functions
3. **Inconsistent** - serialization uses `writer.writeInt()` but deserialization doesn't use `reader.readInt()`

Note: The serialization side (lines 34-38) correctly uses `writer.writeInt()`:
```zig
fn serializeTimestamp(writer: anytype, ts: Timestamp) !void {
    try writer.writeInt(u64, ts.time, .little);
    try writer.writeInt(u16, ts.count, .little);
    try writer.writeInt(u16, ts.node_id, .little);
}
```

## Status

**Not Fixed** - This is a consistency and code cleanliness issue.

## Suggested Fix

Replace the manual read functions with Zig's standard library:

```zig
// Read a little-endian u16 from reader.
fn readU16(reader: anytype) !u16 {
    return reader.readInt(u16, .little);
}

// Read a little-endian u64 from reader.
fn readU64(reader: anytype) !u64 {
    return reader.readInt(u64, .little);
}
```

This is simpler, more maintainable, and consistent with how serialization works.

## Benefits

1. **Less code** - 2 lines instead of ~15
2. **Consistent** - matches the serialization side
3. **Tested** - std library functions are battle-tested
4. **Clear intent** - `readInt(u16, .little)` is self-documenting

## Related Files

- `src/core/event.zig` - Lines 9-24 (readU16 and readU64)
- `src/core/event.zig` - Lines 34-46 (serialization that uses std correctly)

## Reference

- [Zig std.mem.Allocator documentation](https://ziglang.org/documentation/master/std/#A;std:mem.Allocator)
- The `Reader` interface has `readInt`, `readVarInt`, `writeInt`, `writeVarInt` methods

## Priority

**Low** - Works correctly, but could be cleaner

---

*Created: 2026-03-12*
*Status: Not Fixed*
