# Feature: NASA Power of 10 Compliance - Phase 1 (Assertions)

**Date:** 2026-03-12  
**Status:** Complete  
**Feature Number:** 27

## Summary

Implemented Phase 1 of NASA Power of 10 compliance by adding runtime assertions to the codebase. This follows Rule 5 of the Power of 10 guidelines, which requires an average of minimally two assertions per function to check for anomalous conditions that should never happen in real-life executions.

## Background

The [NASA Power of 10 rules](https://en.wikipedia.org/wiki/The_Power_of_10:_Rules_for_Developing_Safety-Critical_Code) were created by Gerard J. Holzmann of NASA/JPL Laboratory for Reliable Software. They are designed to eliminate coding practices that make code difficult to review or statically analyze. While written for C, these rules provide valuable guidance for any safety-conscious codebase.

This implementation specifically addresses **Rule 5: Assertion Density** - requiring minimally two assertions per function to detect anomalous conditions.

## Changes

### New Files

| File | Description |
|------|-------------|
| `src/util/assert.zig` | Runtime assertion library with 7 assertion helpers |

### Modified Files

| File | Assertions Added |
|------|------------------|
| `src/core/event.zig` | 5 assertions for event validation |
| `src/db/wal.zig` | 6 assertions for WAL operations |
| `src/core/reducer.zig` | 8 assertions for reducer validation |
| `src/lib.zig` | Exported assert module |

## Implementation Details

### Assertion Library (`src/util/assert.zig`)

Created a comprehensive runtime assertion library with the following functions:

```zig
// Basic boolean assertion - panics if false
pub inline fn assert(cond: bool, msg: []const u8) void

// Value equality assertion
pub inline fn assertEqual(comptime T: type, expected: T, actual: T, msg: []const u8) void

// Bounds checking [0, max)
pub inline fn assertBounds(val: usize, max: usize, msg: []const u8) void

// Less-than validation
pub inline fn assertLessThan(comptime T: type, val: T, max: T, msg: []const u8) void

// Slice length equality
pub inline fn assertSliceLen(a: []const u8, b: []const u8, msg: []const u8) void

// Negative assertion
pub inline fn assertFalse(cond: bool, msg: []const u8) void

// Unreachable code assertion
pub inline fn assertUnreachable(msg: []const u8) void
```

### Assertions in Event Module (`src/core/event.zig`)

Added assertions to validate:
- Event type is within valid enum bounds
- Checksum is non-zero (should always be set)
- Checksum integrity verification
- `name_len` is within buffer bounds
- `replicas` is in reasonable range (1-127)
- `new_status` is valid enum value (0-3)

### Assertions in WAL (`src/db/wal.zig`)

Added assertions to validate:
- File handle is valid before write operations
- Segment ID won't overflow (limit: 100,000)
- Loop bounds in replay (explicit iteration counter)
- Magic bytes match segment header
- Event count is within reasonable bounds per segment

### Assertions in Reducer (`src/core/reducer.zig`)

Added assertions to validate:
- World state bounds before processing
- `node_id` is non-zero in node_join
- `port` is non-zero in node_join
- `service_id` is non-zero in service_deploy
- `name_len` is in valid range (1-32) in service_deploy
- `replicas` is in valid range (1-127) in service_deploy
- `node_id` is non-zero in health_status_change
- `new_status` is valid enum value (0-3) in health_status_change

## Test Results

All tests pass:

```
✅ zig build test       - Core tests
✅ zig build test-sim   - Simulation tests (12 scenarios)
✅ zig build test-utils - Test utility tests
✅ zig build            - Project builds successfully
```

## Benefits

1. **Runtime Safety**: Detects anomalous conditions that should never happen
2. **Debugging**: Clear panic messages help diagnose issues quickly
3. **Code Documentation**: Assertions serve as executable documentation
4. **Defensive Programming**: Catches bugs early before they cause corruption
5. **NASA Compliance**: Moves toward Power of 10 Rule 5 compliance

## Related Documentation

- [Tech Debt: NASA Power of 10 Compliance Plan](../tech_debt/027-nasa-power-of-10-compliance.md)
- [Documentation: NASA Power of 10 Compliance Guide](../../docs/nasa-power-of-10-compliance.md)
- [Code Complexity Analysis](../tech_debt/020-code-complexity-analysis.md)

## Next Steps

**Phase 2**: Function Size Reduction (Rule 4)
- Refactor `main.zig` - extract parseArgs(), initWorld(), tickLoop()
- Refactor `wal.zig` - split append(), replay(), openOrCreateSegment()
- Target: All functions < 60 lines with CCN < 10

**Phase 3**: Loop Bounds (Rule 2)
- Already partially addressed in Phase 1 (WAL replay loop)
- Add explicit bounds to any remaining unbounded loops

**Phase 4**: Pointer Safety (Rule 9)
- Review optional pointer usage
- Add explicit null checks before dereferencing
