# Tech Debt: WAL Serialization Magic Numbers

## Summary

The WAL serialization code uses magic numbers and manual byte manipulation that could be simplified using Zig's standard library functions.

## Problem Statement

In `src/db/wal.zig`, the `SegmentHeader` serialization uses hardcoded magic numbers and manual byte manipulation:

```zig
// Lines 36-61: Manual byte serialization
fn toBytes(header: SegmentHeader, out: []u8) void {
    @memcpy(out[0..4], &header.magic);
    out[4] = header.version;
    // Magic numbers throughout
    out[5] = @truncate(header.event_count);
    out[6] = @truncate(header.event_count >> 8);
    out[7] = @truncate(header.event_count >> 16);
    out[8] = @truncate(header.event_count >> 24);
    // ... 15 more lines of manual byte manipulation
}
```

Issues:
1. **Magic number `25`** for header size (should be a named constant)
2. **Magic number `65536`** for temp buffer (should be in limits.zig)
3. **Magic number `64 * 1024`** for write buffer (should be in limits.zig)
4. **Manual byte manipulation** instead of using `std.mem.writeInt`

## Status

**Not Fixed** - This is a refactoring opportunity, not a bug.

## Suggested Fix

### Step 1: Add Constants to limits.zig

```zig
// In src/util/limits.zig
pub const WAL_HEADER_SIZE: usize = 25;
pub const WAL_TEMP_BUFFER_SIZE: usize = 65536;
pub const WAL_WRITE_BUFFER_SIZE: usize = 64 * 1024;
pub const WAL_MAX_SEGMENTS: usize = 1000;
```

### Step 2: Use std.mem for Serialization

Replace manual byte manipulation with Zig's standard library:

```zig
// In src/db/wal.zig - SegmentHeader.toBytes
fn toBytes(header: SegmentHeader, out: *[WAL_HEADER_SIZE]u8) void {
    @memcpy(out[0..4], &header.magic);
    out[4] = header.version;
    std.mem.writeInt(u32, out[5..9], header.event_count, .little);
    std.mem.writeInt(u64, out[9..17], header.first_timestamp, .little);
    std.mem.writeInt(u64, out[17..25], header.last_timestamp, .little);
}

// And in fromBytes:
fn fromBytes(bytes: [WAL_HEADER_SIZE]u8) SegmentHeader {
    return .{
        .magic = bytes[0..4].*,
        .version = bytes[4],
        .event_count = std.mem.readInt(u32, bytes[5..9], .little),
        .first_timestamp = std.mem.readInt(u64, bytes[9..17], .little),
        .last_timestamp = std.mem.readInt(u64, bytes[17..25], .little),
    };
}
```

## Benefits

1. **Readability**: Constants make the code self-documenting
2. **Maintainability**: Change buffer sizes in one place
3. **Correctness**: std.mem functions are battle-tested
4. **Consistency**: Matches how Event serialization works

## Related Files

- `src/db/wal.zig` - Lines 36-98 (SegmentHeader serialization)
- `src/util/limits.zig` - Where constants should be added
- `src/core/event.zig` - Example of good serialization patterns

## Priority

**Medium** - Improves maintainability but not critical

---

*Created: 2026-03-12*
*Status: Not Fixed*
