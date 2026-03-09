# Feature: Refactor Reducer to Eliminate Code Duplication

**Status**: ✅ Complete

## Original Ask

Refactor the reducer in `src/core/reducer.zig` to eliminate ~120 lines of duplicate code between `reduce()` and `reduceReplay()` functions.

## Why This Matters

The DRY (Don't Repeat Yourself) principle is important for:
- **Maintainability**: Changes only need to be made in one place
- **Reduced bug risk**: No possibility of code drift between implementations
- **Easier testing**: Single implementation to test

## Problem Identified

The `reduceInner()` (lines 109-236) and `reduceReplay()` (lines 242-324) functions had nearly identical logic:
- Both handle all 5 event types (node_join, node_leave, service_deploy, service_remove, health_status_change)
- Both implement the same state update logic
- The only difference: `reduceInner()` returns effects and errors, `reduceReplay()` returns void

## How It Was Solved

### Changes Made

| File | Change | Description |
|------|--------|-------------|
| `src/core/reducer.zig` | Refactored | Combined reduceInner and reduceReplay into single reduceInternal function |

### Implementation Details

Used a `comptime` flag to eliminate duplication:

```zig
/// Internal reducer implementation.
/// Uses comptime flag to determine whether to emit effects.
fn reduceInternal(
    world: *World, 
    event: Event, 
    comptime emit_effects: bool
) struct { effect: Effect, err: ?ReduceError } {
    switch (event) {
        // ... unified implementation ...
    }
}
```

- `reduce()` calls `reduceInternal(world, event, true)` - emits effects
- `reduceReplay()` calls `reduceInternal(world, event, false)` - no effects

The `comptime` flag allows the compiler to optimize away the effect-related code paths for replay, resulting in no runtime overhead.

## Testing

All tests pass:
```
zig build test
# Exit code: 0
```

## Learnings & Troubleshooting

### Why `comptime`?
Using a `comptime` boolean flag rather than a runtime flag:
1. **Zero runtime cost**: The compiler eliminates the dead code branch entirely
2. **Type safety**: Both code paths are type-checked at compile time
3. **Performance**: No branch prediction or conditional jumps

### Error Handling
The unified function still returns errors for both paths. For replay, the error is simply ignored (the function returns void), which is the desired behavior since replay should not fail catastrophically - it should do its best to recover state.

### Benefits Achieved
1. ~80 lines of code eliminated
2. Single source of truth for event handling logic
3. Easier to add new event types (only one place to change)
4. Ensures replay uses exactly the same logic as live reduction
