# Issue: Code Duplication in Reducer Functions

## Summary
The `reduce()` and `reduceReplay()` functions in `src/core/reducer.zig` contain ~120 lines of nearly identical code. This violates the DRY principle and makes maintenance harder.

## Severity
**MEDIUM** - The code works correctly but is harder to maintain and could drift over time.

## Location
- File: `src/core/reducer.zig`
- Functions: `reduceInner()` (lines 109-236) and `reduceReplay()` (lines 242-324)

## Current Behavior
Both functions implement the same logic for handling each event type:
- node_join: Check if exists, add if not, handle full table
- node_leave: Find and mark as not alive
- service_deploy: Check if exists, add if not, handle full table
- service_remove: Find and remove by shifting
- health_status_change: Find or add health entry

The only difference is:
- `reduce()` returns effects and errors
- `reduceReplay()` returns void (effects are not replayed)

## Expected Behavior
Should have a single implementation that both functions use, with a flag or callback to control effect generation.

## How to Fix
Refactor to use a single core function with a callback:

```zig
// Option 1: Use a callback for effects
fn reduceWithEffect(
    world: *World, 
    event: Event, 
    effect_fn: fn (Effect) void
) ?ReduceError {
    // ... single implementation ...
}

// reduce() calls with effect handler
// reduceReplay() calls with no-op effect handler

// Option 2: Use a flag
fn reduceInternal(
    world: *World, 
    event: Event, 
    comptime emit_effects: bool
) struct { effect: Effect, err: ?ReduceError } {
    // ... single implementation with comptime flag ...
}
```

## Relevant Code
- `src/core/reducer.zig` - Full reducer implementation
- The effect types are defined in lines 20-68
- Tests for reduce are in lines 338-509

## Benefits
1. ~60 lines of code reduction
2. Easier to add new event types (only one place to change)
3. Easier to ensure both functions behave identically
4. Reduces risk of bugs from code drift

## Testing
After refactoring, ensure all existing tests still pass:
```bash
zig build test
```
