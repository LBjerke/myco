# Tech Debt: HLC Time Source Not Abstracted

## Summary

The HLC timestamp implementation directly calls `std.time.milliTimestamp()`, making it difficult to test timestamp ordering without actually waiting for time to pass.

## Problem Statement

In `src/net/hlc.zig`, the time source is hardcoded:

```zig
// Lines 20-22: Hardcoded time source
pub fn now() u64 {
    return std.time.milliTimestamp();
}
```

This makes testing timestamp ordering difficult because:
1. **Tests can't control time** - Must use real wall-clock time
2. **Flaky tests** - Tests may pass/fail based on actual timing
3. **No deterministic ordering** - Can't create timestamps with known ordering

## Status

**Not Fixed** - This is a testability concern.

## Suggested Fix

### Option 1: Global Time Source Function Pointer (Simple)

```zig
// In src/net/hlc.zig

/// Time source function type - can be replaced for testing
var time_source: *const fn () u64 = std.time.milliTimestamp;

pub fn now() u64 {
    return time_source();
}

/// Set a custom time source (for testing)
pub fn setTimeSource(source: *const fn () u64) void {
    time_source = source;
}

/// Reset to default time source
pub fn resetTimeSource() void {
    time_source = std.time.milliTimestamp;
}
```

### Option 2: Time Source as Parameter (More Explicit)

```zig
// In src/net/hlc.zig

pub const Clock = struct {
    time_source: fn () u64,
    
    pub fn init() Clock {
        return .{
            .time_source = std.time.milliTimestamp,
        };
    }
    
    pub fn now(self: *Clock) u64 {
        return self.time_source();
    }
    
    // For testing
    pub fn initWithTime(time: u64) Clock {
        return .{
            .time_source = struct {
                var fixed_time = time;
                pub fn get() u64 {
                    return fixed_time;
                }
            }.get,
        };
    }
};
```

### Option 3: Fixed Timestamps for Testing (Simplest)

```zig
// In test file
test "Timestamp ordering works" {
    // Create timestamps directly with known values
    const ts1 = Timestamp{ .time = 1000, .count = 0, .node_id = 1 };
    const ts2 = Timestamp{ .time = 1001, .count = 0, .node_id = 1 };
    
    try std.testing.expect(Timestamp.lessThan(ts1, ts2));
}
```

Option 3 is already possible since `Timestamp` is a `packed struct` - you can construct it directly with known values. The main issue is the `now()` function.

## Example: Testing with Option 1

```zig
test "HLC clock advances" {
    // Save original time source
    const original = hlc.time_source;
    defer hlc.resetTimeSource();
    
    // Set fixed time source
    var call_count: usize = 0;
    hlc.time_source = struct {
        var time: u64 = 1000;
        pub fn get() u64 {
            time += 1;
            return time;
        }
    }.get;
    
    // Now test behavior
    const ts1 = hlc.now();
    const ts2 = hlc.now();
    
    try std.testing.expect(ts1 < ts2);
}
```

## Benefits

1. **Testable** - Can control time in tests
2. **Deterministic** - No flaky tests based on actual timing
3. **Flexible** - Can use different time sources (mock, real, etc.)
4. **Backward compatible** - Default behavior unchanged

## Related Files

- `src/net/hlc.zig` - Lines 20-22 (time source)
- `src/core/event.zig` - Uses Timestamp (consumer of HLC)
- Tests would benefit from abstraction

## Reference

- [Zig std.time documentation](https://ziglang.org/documentation/master/std/#A;std:time)
- Similar patterns used in other languages for time abstraction (e.g., Java's `Clock`)

## Priority

**Low** - Nice to have for testing, but not critical since Timestamps can be constructed directly

---

*Created: 2026-03-12*
*Status: Not Fixed*
