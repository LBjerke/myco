# Feature: Frozen Allocator (Zero-Allocation Runtime)

## Status: ✅ Complete

## Original Ask

Implement a frozen allocator pattern similar to TigerBeetle to ensure zero-allocation runtime after initialization. This ensures deterministic memory usage and prevents accidental heap allocations during the tick loop.

## Where Code Was Added/Changed

### Files Created

| File | Purpose |
|------|---------|
| `src/util/allocator.zig` | FrozenAllocator implementation |
| `src/main.zig` | Updated to use frozen allocator |

### Code Added

```zig
// src/util/allocator.zig

/// A frozen allocator that prevents allocations after initialization.
/// Once frozen, any allocation attempt will panic.
pub const FrozenAllocator = struct {
    buffer: []u8,
    offset: usize = 0,
    frozen: bool = false,

    pub fn init(buffer: []u8) FrozenAllocator { ... }
    pub fn allocator(self: *FrozenAllocator) std.mem.Allocator { ... }
    pub fn freeze(self: *FrozenAllocator) void { ... }
    // ...
};

// Global 64KB buffer
var init_buffer: [INIT_ALLOCATOR_SIZE]u8 = undefined;
var frozen_allocator: FrozenAllocator = undefined;

pub fn init() void { ... }
pub fn getAllocator() std.mem.Allocator { ... }
pub fn freeze() void { ... }
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Startup Sequence                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. allocator_mod.init()     → 64KB buffer allocated      │
│  2. getAllocator()           → Returns alloc interface    │
│  3. [USE ALLOCATOR]          → Parse config, WAL replay   │
│  4. allocator_mod.freeze()    → CRITICAL: locks allocator  │
│  5. [RUNTIME LOOP]           → Any alloc attempt PANICS!   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Memory Layout

```
┌─────────────────────────────────────┐
│ Static Buffer (64KB, .bss section)  │
├─────────────────────────────────────┤
│ Used during init:                   │
│ - Config parsing                    │
│ - WAL replay                        │
│ - Dynamic structures                │
├─────────────────────────────────────┤
│ After freeze:                       │
│ - No more allocations               │
│ - Runtime tick loop runs            │
└─────────────────────────────────────┘
```

## Usage

```zig
pub fn main() !void {
    // Initialize frozen allocator
    allocator_mod.init();
    const alloc = allocator_mod.getAllocator();
    
    // === INIT PHASE: Use allocator for dynamic structures ===
    
    // Example: parse config file
    var config = try parseConfig(alloc, config_path);
    
    // Example: initialize WAL
    var wal = try Wal.init(alloc, wal_path);
    try wal.replay(&world);
    
    // Log init memory usage
    std.debug.print("Init complete. Used {} bytes of {}.\n", .{
        allocator_mod.INIT_ALLOCATOR_SIZE - allocator_mod.remaining(),
        allocator_mod.INIT_ALLOCATOR_SIZE,
    });
    
    // === FREEZE: No more allocations allowed! ===
    allocator_mod.freeze();
    std.debug.print("Allocator frozen. Zero-allocation runtime active.\n", .{});

    // Initialize ECS World (fixed arrays, no allocation)
    var world = World.init();

    // Main tick loop - all allocation attempts will panic
    while (true) {
        std.Thread.sleep(limits.TICK_INTERVAL_MS * std.time.ns_per_ms);
        // Process events - no heap allocations allowed!
    }
}
```

## Testing

- Build verification: `zig build` passes
- Runtime test: `./zig-out/bin/myco` runs without panic
- Output shows:
  ```
  Myco (greenfield) starting...
  Init complete. Used 16 bytes of 65536.
  Allocator frozen. Zero-allocation runtime active.
  World initialized. Entering tick loop...
  ```

## Key Features

| Feature | Description |
|---------|-------------|
| **Static buffer** | 64KB fixed, no heap |
| **Freeze mechanism** | Any allocation after freeze → panic |
| **Deterministic** | Same memory usage every run |
| **Simple** | No VM magic, no complex arena |
| **Zig 0.15 compatible** | Uses new Allocator VTable with `remap` |

## Comparison to Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **Frozen Allocator** | Simple, deterministic | Fixed buffer size |
| **TigerBeetle VM** | Can address huge space | Complex, overkill for small data |
| **Arena + reset** | Flexible | Requires discipline to reset |

## Next Steps

- Add integration test that verifies panic on post-freeze allocation
- Consider reducing buffer size if init uses less than 64KB
- Add WAL integration that uses this allocator during replay

## Summary

Implemented zero-allocation runtime pattern:
- 64KB static buffer for init-time allocations
- FrozenAllocator that panics on any post-freeze allocation
- Main loop protected from accidental heap usage
- Deterministic memory footprint
