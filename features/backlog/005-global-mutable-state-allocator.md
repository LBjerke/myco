# Issue: Global Mutable State in FrozenAllocator

## Summary
The FrozenAllocator uses global mutable state (`frozen_allocator` variable) which makes the code not thread-safe and harder to test in isolation.

## Severity
**MEDIUM** - Works for current single-threaded use case, but limits future extensibility.

## Location
- File: `src/util/allocator.zig`
- Variables: 
  - Line 139: `var init_buffer: [INIT_ALLOCATOR_SIZE]u8 = undefined;`
  - Line 142: `var frozen_allocator: FrozenAllocator = undefined;`

## Current Behavior
```zig
// Line 142
var frozen_allocator: FrozenAllocator = undefined;

// Line 145-147
pub fn init() void {
    frozen_allocator = FrozenAllocator.init(&init_buffer);
}

// Line 150-152
pub fn getAllocator() std.mem.Allocator {
    return frozen_allocator.allocator();
}
```

## Problems
1. **Not thread-safe**: Multiple threads calling `init()` or `getAllocator()` would race
2. **Hard to test**: Can't have isolated allocator instances for testing
3. **Can't run multiple instances**: No way to have two independent allocators
4. **Global state pollution**: Contaminates the global namespace

## How to Fix
Option 1 (Recommended): Return allocator from init
```zig
pub fn init() FrozenAllocator {
    return FrozenAllocator.init(&init_buffer);
}

// In main.zig:
const allocator = allocator_mod.init();
const alloc = allocator.allocator();
```

Option 2: Use a proper singleton pattern with thread safety
```zig
var once_mutex: std.Thread.Mutex = undefined;
var initialized: bool = false;

pub fn init() void {
    once_mutex.lock();
    defer once_mutex.unlock();
    // ... initialization ...
}
```

Option 3: Pass allocator as parameter throughout the codebase
- More verbose but most explicit

## Relevant Code
- `src/main.zig` - Shows how allocator is currently used
- `src/db/wal.zig` - Would need to accept allocator as parameter

## Considerations
- Current codebase is single-threaded (tick loop in main.zig doesn't spawn threads)
- If keeping global state, at least add thread-local storage or mutex
- Consider using `std.mem.Allocator` pattern consistently throughout

## Testing
After fix, verify:
1. Existing tests still pass
2. Can create multiple independent allocator instances if needed
