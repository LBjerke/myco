# Tech Debt: NASA Power of 10 Compliance

**Date:** 2026-03-12  
**Status:** ALL PHASES COMPLETE  
**Priority:** High  
**Reference:** [NASA Power of 10 Rules](https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code)

## Summary

Adopt the NASA Power of 10 coding guidelines to improve code safety, testability, and maintainability. This is a safety-critical systems standard that will reduce bugs and make the codebase easier to reason about.

## Background

The Power of 10 rules were created by Gerard J. Holzmann of NASA/JPL Laboratory for Reliable Software in 2006. They are intended to eliminate C coding practices that make code difficult to review or statically analyze. While our codebase is in Zig (not C), these rules provide valuable guidance for building reliable, maintainable software.

## Current State Analysis

| Rule | Description | Current Status |
|------|-------------|----------------|
| 1 | Simple control flow (no goto, recursion) | ✅ Compliant - Zig has no goto |
| 2 | Bounded loops | 🟡 Partial - Need explicit bounds |
| 3 | No dynamic memory after init | ✅ Compliant - FrozenAllocator used |
| 4 | Functions < 60 lines | 🔴 Needs work - main.zig (185 lines) |
| 5 | 2+ assertions per function | 🔴 Needs work - Add runtime asserts |
| 6 | Minimal scope | ✅ Compliant |
| 7 | Check all return values | ✅ Compliant - Zig's try/catch |
| 8 | Limited preprocessor | ✅ Compliant - Zig has no C preprocessor |
| 9 | Restrict pointers | 🟡 Partial - Review optional pointers |
| 10 | Compile with warnings | ✅ Compliant |

### Code Complexity Baseline (from Lizard analysis)

| File | Function | CCN | Lines | Status |
|------|----------|-----|-------|--------|
| `src/main.zig` | `main` | 41 | 185 | 🔴 Needs refactor |
| `src/db/wal.zig` | `replay` | 21 | 83 | 🔴 Needs refactor |
| `src/db/wal.zig` | `append` | 21 | 69 | 🔴 Needs refactor |
| `src/db/wal.zig` | `openOrCreateSegment` | 16 | 57 | 🔴 Needs refactor |
| `src/core/event.zig` | `deserialize` | 14 | 17 | 🟡 Could improve |
| `src/core/event.zig` | `serialize` | 12 | 10 | 🟡 Could improve |

---

## Implementation Plan

### Phase 1: Assertion Density (Rule 5) - Highest Priority

**Goal:** Add runtime assertions to detect anomalous conditions that should never happen in real execution.

#### 1.1 Create Assertion Library

Create `src/util/assert.zig`:

```zig
/// Runtime assertion helpers for safety-critical code
/// Follows NASA Power of 10 Rule 5

/// Assert a condition is true - panics with message if false
pub inline fn assert(cond: bool, msg: []const u8) void {
    if (!cond) @panic(msg);
}

/// Assert a pointer is not null
pub inline fn assertNotNull(ptr: anytype, msg: []const u8) void {
    if (ptr == null) @panic(msg);
}

/// Assert value is within bounds
pub inline fn assertBounds(val: usize, max: usize, msg: []const u8) void {
    if (val >= max) @panic(msg);
}

/// Assert two values are equal
pub inline fn assertEqual(comptime T: type, a: T, b: T, msg: []const u8) void {
    if (a != b) @panic(msg);
}
```

#### 1.2 Add Assertions to Event Processing

**File:** `src/core/event.zig`

Add assertions for:
- Event type is valid (within enum bounds)
- Buffer has sufficient bytes before reading
- Checksum validation (already exists, verify it's used)

#### 1.3 Add Assertions to WAL

**File:** `src/db/wal.zig`

Add assertions for:
- Loop iteration bounds don't exceed limits
- Segment file handles are valid
- Buffer positions are within bounds
- Event count matches header

#### 1.4 Add Assertions to Reducer

**File:** `src/core/reducer.zig`

Add assertions for:
- State transitions are valid
- Required components exist before access
- Entity IDs are within valid range

---

### Phase 2: Function Size Reduction (Rule 4)

**Goal:** Reduce all functions to 60 lines or less with CCN < 10.

#### 2.1 Refactor `main.zig`

Current: `main()` has CCN=41 (185 lines)

Extract the following functions:
- `parseArgs()` - Command-line argument parsing (~40 lines)
- `initWorld()` - World initialization (~80 lines)  
- `tickLoop()` - Main event loop tick (~20 lines)

Target: `main()` reduced to ~40 lines with CCN < 10

#### 2.2 Refactor `wal.zig`

**`append()` (CCN=21, 69 lines):**
Split into:
- `writeAtomic()` - Atomic write operation
- `updateSegmentHeader()` - Header update logic
- `shouldRotate()` - Segment rotation decision

**`replay()` (CCN=21, 83 lines):**
Split into:
- `collectSegmentIds()` - Scan directory for segments
- `replaySingleSegment()` - Replay one segment file
- `validateReplayState()` - Post-replay validation

**`openOrCreateSegment()` (CCN=16, 57 lines):**
Split into:
- `findMaxSegmentId()` - Find highest segment number
- `createSegmentFile()` - Create new segment
- `openExistingSegment()` - Open existing segment

---

### Phase 3: Loop Bounds (Rule 2)

**Goal:** Ensure all loops have provable upper bounds.

#### 3.1 Fix WAL Replay Infinite Loop Bug

**File:** `src/db/wal.zig`, line 392

Current issue:
```zig
while (local_count < header.event_count and pos < buffer_slice.len) {
    const event_buffer = buffer_slice[pos..];
    var fbs = std.io.fixedBufferStream(event_buffer);
    const wal_event = try WalEvent.deserialize(fbs.reader());
    
    pos += fbs.pos;  // BUG: If fbs.pos == 0 (malformed), infinite loop!
    local_count += 1;
}
```

Fix:
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

#### 3.2 Add Explicit Loop Bounds

Add iteration counters with assertions to all while loops:
```zig
var iterations: usize = 0;
const max_iterations = 1000; // Proven upper bound
while (...) {
    assert(iterations < max_iterations, "Loop exceeded max iterations");
    iterations += 1;
    // ...
}
```

---

### Phase 4: Pointer Safety (Rule 9)

**Goal:** Ensure all pointer dereferences are explicit and safe.

#### 4.1 Audit Pointer Usage

Review `src/db/wal.zig` for:
- Optional pointer (`?*T`) usage
- Null checks before dereference
- No hidden pointer dereferences in macros

#### 4.2 Add Pointer Assertions

```zig
// Before dereferencing optional pointer
assertNotNull(ptr, "Segment handle must not be null");
const value = ptr.*;
```

---

## Target Metrics

| Metric | Before | After |
|--------|--------|-------|
| Max CCN | 41 | < 10 |
| Avg CCN | 4.8 | < 4 |
| Functions > 60 lines | 4 | 0 |
| Assertions per function | ~0.2 | 2+ |
| Functions with unbounded loops | 1 | 0 |

---

## Testing Checklist

After implementation:
- [ ] All existing tests pass (`zig test`)
- [ ] New assertion helpers have tests
- [ ] Lizard reports CCN < 10 for all functions
- [ ] No runtime panics from assertions in normal operation
- [ ] Code compiles with `-Werror` equivalent warnings

---

## Related Files

- `src/util/assert.zig` - New assertion library
- `src/main.zig` - Refactor main function
- `src/db/wal.zig` - Add assertions, refactor functions
- `src/core/event.zig` - Add assertions
- `src/core/reducer.zig` - Add assertions
- `docs/nasa-power-of-10-compliance.md` - Full documentation

---

## References

- [The Power of 10: Rules for Developing Safety-Critical Code](https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code)
- [JPL C Coding Standard](https://www.jpl.nasa.gov/info/policies/CodingStandard.pdf)
- NASA study of Toyota unintended acceleration (found 243 violations)
