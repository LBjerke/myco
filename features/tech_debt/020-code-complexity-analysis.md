# Tech Debt: Code Complexity Analysis

**Date:** 2026-03-10  
**Analyst:** Code Review (Lizard CCN Analysis)  
**Status:** Backlog

## Summary

This document outlines code quality issues identified via cyclomatic complexity analysis using Lizard. The goal is to reduce complexity to make the codebase easier to understand and maintain for new contributors.

## Lizard Analysis Results

```
Total files analyzed: 8
Total functions: 60
Average CCN: 4.8
Warning threshold: CCN > 15
```

### High Complexity Functions (CCN > 10)

| File | Function | CCN | Lines | Status |
|------|----------|-----|-------|--------|
| `src/main.zig` | `main` | 41 | 185 | 🔴 Needs refactor |
| `src/db/wal.zig` | `replay` | 21 | 83 | 🔴 Needs refactor |
| `src/db/wal.zig` | `append` | 21 | 69 | 🔴 Needs refactor |
| `src/db/wal.zig` | `openOrCreateSegment` | 16 | 57 | 🔴 Needs refactor |
| `src/core/event.zig` | `deserialize` (Event) | 14 | 17 | 🟡 Could improve |
| `src/core/event.zig` | `serialize` (Event) | 12 | 10 | 🟡 Could improve |

**Target:** All functions should have CCN < 10 for easy reasoning.

---

## 🐛 Bugs Found

### 1. Potential Infinite Loop in WAL Replay

**File:** `src/db/wal.zig`  
**Location:** Line 392  
**Severity:** Critical

```zig
while (local_count < header.event_count and pos < buffer_slice.len) {
    const event_buffer = buffer_slice[pos..];
    var fbs = std.io.fixedBufferStream(event_buffer);
    const wal_event = try WalEvent.deserialize(fbs.reader());
    
    pos += fbs.pos;  // BUG: If fbs.pos == 0 (malformed data), infinite loop!
    local_count += 1;
}
```

**Fix:**
```zig
while (local_count < header.event_count and pos < buffer_slice.len) {
    const event_buffer = buffer_slice[pos..];
    var fbs = std.io.fixedBufferStream(event_buffer);
    const wal_event = try WalEvent.deserialize(fbs.reader());
    
    // Guard against infinite loop if deserialization doesn't advance
    if (fbs.pos == 0) {
        return error.InvalidEventData;
    }
    pos += fbs.pos;
    local_count += 1;
}
```

### 2. Outdated Comment in Checksum Documentation

**File:** `src/core/event.zig`  
**Location:** Line 300  
**Severity:** Low (documentation)

The comment says:
```zig
/// Also note: the checksum is currently written but never verified during WAL reads.
```

This is **incorrect** - the checksum IS verified in `WalEvent.deserialize` at lines 283-287:

```zig
// Verify checksum
const calculated_checksum = calculateChecksum(event);
if (calculated_checksum != checksum) {
    return error.ChecksumMismatch;
}
```

**Fix:** Remove or update the misleading comment.

---

## 🔄 Code Duplication

### 1. Timestamp Serialization (5 instances)

**Location:** `src/core/event.zig`  
Each event type duplicates:

```zig
// In NodeJoinEvent, NodeLeaveEvent, ServiceDeployEvent, ServiceRemoveEvent, HealthStatusChangeEvent:
try writer.writeInt(u64, self.timestamp.time, .little);
try writer.writeInt(u16, self.timestamp.count, .little);
try writer.writeInt(u16, self.timestamp.node_id, .little);
```

**Solution:** Extract helper functions:

```zig
fn serializeTimestamp(writer: anytype, ts: Timestamp) !void {
    try writer.writeInt(u64, ts.time, .little);
    try writer.writeInt(u16, ts.count, .little);
    try writer.writeInt(u16, ts.node_id, .little);
}

fn deserializeTimestamp(reader: anytype) !Timestamp {
    const time = try reader.readInt(u64, .little);
    const count = try reader.readInt(u16, .little);
    const node_id = try reader.readInt(u16, .little);
    return .{ .time = time, .count = count, .node_id = node_id };
}
```

### 2. Path Formatting (4 instances)

**Location:** `src/db/wal.zig`

Repeated in:
- `openOrCreateSegment` (line 186)
- `append` (line 235)
- `replay` (line 356)
- `getTotalEventCount` (line 431)

**Solution:** Extract helper:

```zig
fn formatSegmentPath(
    buffer: *std.io.FixedBufferStream([]u8),
    dir: []const u8,
    id: u32,
) ![]const u8 {
    try buffer.writer().print("{s}/segment-{:0>4}", .{ dir, id });
    return buffer.getWritten();
}
```

---

## 📝 Refactoring Plan

### Priority 1: Critical (Fix Bugs)

- [ ] Fix infinite loop bug in `wal.zig` replay function
- [ ] Fix outdated checksum comment in `event.zig`

### Priority 2: High (Reduce Complexity)

#### 2.1 Refactor `main.zig`

Current: `main()` has CCN=41 (185 lines)

Extract the following functions:

```zig
// Extract argument parsing (~40 lines)
fn parseArgs() !struct {
    data_dir: []const u8,
    show_help: bool,
    show_version: bool,
    config_path: ?[]const u8,
    command: ?[]const u8,
}

// Extract init phase setup (~30 lines)
fn initWorld(allocator, data_dir) !World

// Extract event loop tick (~10 lines) 
fn tickLoop() noreturn
```

**Target:** Reduce `main()` to ~40 lines with CCN < 10.

#### 2.2 Refactor `wal.zig`

**`openOrCreateSegment`** (CCN=16):
```zig
// Split into:
fn findMaxSegmentId(dir_path, allocator) !u32
fn createSegmentFile(id, dir_path, allocator) !void
fn openExistingSegment(id, dir_path) !void
```

**`append`** (CCN=21):
```zig
// Split into:
fn writeAtomic(temp_path, existing_data, event_data) !void
fn updateSegmentHeader() !void
fn shouldRotate() bool
```

**`replay`** (CCN=21):
```zig
// Split into:
fn collectSegmentIds(dir_path, allocator) ![100]u32
fn replaySingleSegment(segment_id, ctx, applyFn) !void
```

### Priority 3: Medium (Remove Duplication)

- [ ] Extract timestamp serialization helpers in `event.zig`
- [ ] Extract path formatting helper in `wal.zig`

---

## Benefits of Refactoring

| Metric | Before | After |
|--------|--------|-------|
| Max CCN | 41 | < 10 |
| Avg CCN | 4.8 | < 4 |
| Functions > 15 | 4 | 0 |
| Duplicate timestamp code | 5 instances | 1 helper |
| Duplicate path formatting | 4 instances | 1 helper |

**New contributor experience:**
- Functions are small enough to understand in one read
- No hidden control flow complexity
- Clear separation of concerns
- Easier to test individual components

---

## Testing Checklist

After refactoring, verify:

- [ ] All existing tests pass (`zig test`)
- [ ] New helper functions have unit tests
- [ ] Edge cases covered (empty segments, malformed data, etc.)
- [ ] Lizard reports CCN < 10 for all functions

---

## Related Files

- `src/main.zig` - CLI entry point
- `src/db/wal.zig` - Write-ahead log
- `src/core/event.zig` - Event types
- `src/core/reducer.zig` - Event processing
- `src/ecs/world.zig` - State container

---

## Notes

-CCN (Cyclomatic Complexity Number) counts the number of linearly independent paths through code
- Target of < 10 follows industry best practice for "easy to reason about" code
- The frozen allocator pattern is working correctly - no changes needed there
