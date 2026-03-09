# Issue: Undefined Arrays in World.init

## Summary
The `World.init()` function sets array fields to `undefined` rather than explicitly initializing them to zero. While technically valid in Zig, this is potentially confusing and could hide bugs.

## Severity
**LOW** - Code clarity issue. The current code works because the count fields are set to 0, so the undefined data in unused slots is never accessed.

## Location
- File: `src/ecs/world.zig`
- Lines 198-216 in `World.init()`

## Current Behavior
```zig
// Lines 199-215
pub fn init() World {
    return World{
        // Node components
        .nodes = undefined,         // Could be confusing
        .node_count = 0,
        .node_metas = undefined,
        .node_meta_count = 0,
        .node_health = undefined,
        .node_health_count = 0,

        // Service components
        .services = undefined,
        .service_count = 0,
        .service_runtimes = undefined,
        .service_runtime_count = 0,
        .placements = undefined,
        .placement_count = 0,
    };
}
```

## Why It Works
Zig arrays default-initialized with `undefined` contain arbitrary data, but:
- Only `0..count` elements are ever accessed
- The count fields are explicitly set to 0
- So the undefined data is never read

## How to Fix
Option 1: Use explicit zero initialization (clearer)
```zig
pub fn init() World {
    return World{
        .nodes = .{0} ** limits.MAX_NODES,
        .node_count = 0,
        .node_metas = .{0} ** limits.MAX_NODES,
        .node_meta_count = 0,
        // ... etc
    };
}
```

Option 2: Use @sentinelOf for active flags
```zig
.nodes = .{.{.id = 0, .alive = false}} ** limits.MAX_NODES,
```

Option 3: Keep as-is (acceptable)
- Document why undefined is safe here
- Add a comment explaining that counts are always initialized

## Note
This pattern is common in Zig for performance (avoiding redundant initialization of data that will be overwritten). However, explicit zeros would be clearer for maintenance.
