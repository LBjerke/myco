# Tech Debt: WAL Path Parsing Magic String

## Summary

The WAL segment file path parsing uses magic strings that are repeated throughout the code, making it fragile if the naming convention ever changes.

## Problem Statement

In `src/db/wal.zig`, the segment filename prefix is hardcoded in multiple places:

```zig
// Line 186: In openOrCreateSegment
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
    const id = std.fmt.parseInt(u32, entry.path[8..], 10) catch continue;
}

// Line 344: In replay
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
    const id = std.fmt.parseInt(u32, entry.path[8..], 10) catch continue;
}

// Line 434: In getTotalEventCount
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
    const segment_path = self.formatPath("{s}/{s}", .{ self.dir_path, entry.path }) catch continue;
}
```

**Issues:**
1. **Magic string `"segment-"`** - repeated 3+ times
2. **Magic number `8`** - the length of "segment-" is hardcoded as slice offset
3. **Fragile** - change to filename format requires updating multiple locations
4. **Error-prone** - if prefix length changes, offset must be manually updated

## Status

**Not Fixed** - This is a code maintainability issue.

## Suggested Fix

### Add Constants for Filename Patterns

```zig
// At the top of src/db/wal.zig
const SEGMENT_PREFIX = "segment-";
const SEGMENT_PREFIX_LEN = SEGMENT_PREFIX.len;  // 8
const TEMP_PREFIX = ".tmp-";
const TEMP_PREFIX_LEN = TEMP_PREFIX.len;  // 5
const SEGMENT_FORMAT = "segment-{:0>4}";  // For path formatting
```

### Use Constants Throughout

```zig
// In openOrCreateSegment
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, SEGMENT_PREFIX)) {
    const id = std.fmt.parseInt(u32, entry.path[SEGMENT_PREFIX_LEN..], 10) catch continue;
}

// In replay
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, SEGMENT_PREFIX)) {
    const id = std.fmt.parseInt(u32, entry.path[SEGMENT_PREFIX_LEN..], 10) catch continue;
}

// In getTotalEventCount
if (entry.kind == .file and std.mem.startsWith(u8, entry.path, SEGMENT_PREFIX)) {
    // ...
}
```

### Alternative: Helper Function

```zig
/// Extract segment ID from filename, or return null if not a segment file
fn extractSegmentId(path: []const u8) ?u32 {
    if (std.mem.startsWith(u8, path, SEGMENT_PREFIX)) {
        return std.fmt.parseInt(u32, path[SEGMENT_PREFIX_LEN..], 10) catch null;
    }
    return null;
}
```

## Benefits

1. **Single source of truth** - change filename format in one place
2. **Self-documenting** - constants explain what the strings mean
3. **Compile-time checking** - SEGMENT_PREFIX_LEN is calculated from the string
4. **Easier testing** - helper function can be tested in isolation

## Related Files

- `src/db/wal.zig` - Lines 186, 344, 434 (all uses of segment filename)
- `src/db/wal.zig` - Line 194 (segment path formatting)
- `src/db/wal.zig` - Line 241 (temp file naming)

## Priority

**Low** - Low impact, but easy to fix and improves maintainability

---

*Created: 2026-03-12*
*Status: Not Fixed*
