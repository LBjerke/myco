# Tech Debt: WAL Segment Discovery Hardcoded Limit

## Summary

The WAL segment discovery uses a fixed-size array with a hardcoded limit of 100 segments, which could silently fail if a node has been running long enough to create more segments.

## Problem Statement

In `src/db/wal.zig`, the `replay` function uses a fixed-size array:

```zig
// Line 337-338: Hardcoded limit
var segments: [100]u32 = undefined;
var segment_count: usize = 0;
```

Similarly, in `getTotalEventCount`:

```zig
// Line 437-441: Also hardcoded, but uses continue on error
const segment_path = self.formatPath("{s}/{s}", .{ self.dir_path, entry.path }) catch continue;
```

**Issues:**
1. **Magic number `100`** - not configurable, no constant
2. **Silent truncation** - if more than 100 segments exist, they're silently ignored
3. **No warning** - user wouldn't know events were missed

## Status

**Not Fixed** - This is a scalability limitation.

## Suggested Fix

### Option 1: Add Constant (Minimal Change)

```zig
// Add to src/util/limits.zig
pub const WAL_MAX_SEGMENTS: usize = 1000;

// In src/db/wal.zig
var segments: [limits.WAL_MAX_SEGMENTS]u32 = undefined;
```

### Option 2: Use Dynamic List (More Complete)

```zig
// Use a dynamic list for segment tracking
var segment_list = std.ArrayList(u32).init(allocator);
defer segment_list.deinit();

// Append segments
try segment_list.append(id);

// Use slice for iteration
for (segment_list.items) |segment_id| {
    // ...
}
```

### Option 3: Error on Overflow (Most Robust)

```zig
const MAX_SEGMENTS = 1000;
var segments: [MAX_SEGMENTS]u32 = undefined;
var segment_count: usize = 0;

// In the loop:
if (segment_count >= MAX_SEGMENTS) {
    return error.TooManySegments;  // Fail fast
}
segments[segment_count] = id;
segment_count += 1;
```

## Benefits

1. **Scalability**: Handle nodes that have been running for extended periods
2. **Visibility**: Option 3 fails fast with a clear error
3. **Configurability**: Constants allow tuning for different deployments

## Related Files

- `src/db/wal.zig` - Lines 337-351 (replay function)
- `src/db/wal.zig` - Lines 423-454 (getTotalEventCount function)
- `src/util/limits.zig` - Where constant should be added

## Priority

**Medium** - Low probability of hitting in practice, but could cause data loss if triggered

---

*Created: 2026-03-12*
*Status: Not Fixed*
