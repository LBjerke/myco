# Feature: NASA Power of 10 Compliance - Phase 4 (Pointer Safety)

**Date:** 2026-03-12  
**Status:** Complete (with documented exceptions)  
**Feature Number:** 30

## Summary

Phase 4 of NASA Power of 10 compliance audits pointer usage in the codebase. While most pointer usage is compliant, two function pointer patterns require documentation as intentional exceptions.

## Background

**Rule 9 of NASA Power of 10:**
- No more than one level of dereference should be used
- Pointer dereference operations may not be hidden in macros or typedefs
- **Function pointers are not permitted**

## Audit Results

### Pointer Usage Summary

| Pattern | Location | Compliant | Notes |
|---------|----------|-----------|-------|
| No double dereferences (**) | All | ✅ | None found |
| Optional pointers (?*T) | world.zig | ✅ | Properly null-checked |
| Function pointers | hlc.zig | ⚠️ | Exception - see below |
| Function pointers | wal.zig | ⚠️ | Exception - see below |

### Detailed Findings

#### 1. Optional Pointers (Compliant ✅)

The `World` struct returns optional pointers from finder functions:

```zig
pub fn findNode(self: *const World, node_id: u16) ?*const Node
pub fn findService(self: *const World, service_id: u16) ?*const ServiceSpec
pub fn findPlacement(self: *const World, service_id: u16, replica_id: u8) ?*const ServicePlacement
```

These are properly used by callers with Zig's null-safe pattern:

```zig
if (world.findNode(node_id)) |node| {
    // Use node
}
```

#### 2. Function Pointer: HLC Time Source (Exception ⚠️)

**Location:** `src/net/hlc.zig`

```zig
var time_source: *const fn () u64 = std.time.milliTimestamp;

pub fn now() u64 {
    return time_source();
}

pub fn setTimeSource(source: *const fn () u64) void {
    time_source = source;
}
```

**Rationale for exception:**
- Allows time source injection for deterministic testing
- Documented in `features/tech_debt/026-hlc-time-source-abstraction.md`
- This is a common testing pattern in embedded systems

#### 3. Function Pointer: WAL Replay Callback (Exception ⚠️)

**Location:** `src/db/wal.zig`

```zig
pub fn replay(self: *Wal, ctx: anytype, applyFn: fn (@TypeOf(ctx), Event) void) !void
```

**Rationale for exception:**
- Standard functional programming pattern for iteration
- Enables reusable replay logic with different handlers
- Equivalent to C's `typedef` callback pattern

## Compliance Status

| Requirement | Status |
|-------------|--------|
| No double dereferences | ✅ Compliant |
| No hidden pointer dereferences | ✅ Compliant |
| Optional pointers have null checks | ✅ Compliant |
| No function pointers | ⚠️ 2 documented exceptions |

## Recommendations

If strict NASA compliance is required:

1. **HLC Time Source**: Replace with compile-time time source selection using `comptime`:
   ```zig
   pub const TimeSource = enum { wall_clock, mock };
   ```

2. **WAL Replay**: Replace callback with interface pattern or duplicate replay logic per handler.

However, these changes would reduce testability and code reusability. The current implementation follows well-established patterns in systems programming.

## Test Results

All tests pass:

```
✅ zig build test       - Core tests
✅ zig build test-sim   - Simulation tests (12 scenarios)
✅ zig build           - Project builds
```

## Related Documentation

- [Tech Debt: NASA Power of 10 Compliance Plan](../tech_debt/027-nasa-power-of-10-compliance.md)
- [Documentation: NASA Power of 10 Compliance Guide](../../docs/nasa-power-of-10-compliance.md)
- [Tech Debt: HLC Time Source Abstraction](../tech_debt/026-hlc-time-source-abstraction.md)
- [Phase 1: Assertions](./27-nasa-power-of-10-phase1-assertions.md)
- [Phase 2: Function Size](./28-nasa-power-of-10-phase2-function-size.md)
- [Phase 3: Loop Bounds](./29-nasa-power-of-10-phase3-loop-bounds.md)

## Completed Phases

| Phase | Rule | Status |
|-------|------|--------|
| 1 | Rule 5: Assertions | ✅ Complete |
| 2 | Rule 4: Function Size | ✅ Complete |
| 3 | Rule 2: Loop Bounds | ✅ Complete |
| 4 | Rule 9: Pointers | ✅ Complete (documented exceptions) |

## All NASA Power of 10 Rules Summary

| # | Rule | Status |
|---|------|--------|
| 1 | Simple control flow | ✅ No goto/recursion |
| 2 | Bounded loops | ✅ All loops bounded |
| 3 | No dynamic memory | ✅ FrozenAllocator |
| 4 | Function size < 60 lines | ✅ All CCN < 10 |
| 5 | 2+ assertions per function | ✅ Implemented |
| 6 | Minimal scope | ✅ Zig encourages this |
| 7 | Check return values | ✅ Zig's try/catch |
| 8 | Limited preprocessor | ✅ Zig has none |
| 9 | Restricted pointers | ⚠️ 2 documented exceptions |
| 10 | Compiler warnings | ✅ Enabled |
