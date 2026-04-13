# Feature: O(1) Index-Based Lookups for ECS

> Status: 🔄 Planned (Feature 24 Phase 1)

## Summary

Replace O(n) linear search for node and service lookups with O(1) array index lookups. This is the foundational performance optimization that enables all subsequent optimizations.

## Original Ask

The current ECS uses linear search to find nodes and services:
```zig
// Current: O(n) - iterates through all nodes
for (world.nodes[0..world.node_count]) |node| {
    if (node.node_id == target) return node;
}
```

This needs to be replaced with O(1) index-based lookup:
```zig
// After: O(1) - direct array access
const idx = world.node_index[target];
return &world.nodes[idx];
```

## Implementation

### Index Arrays

```zig
/// World now includes index arrays for O(1) lookups
pub const World = struct {
    // Node components (unchanged)
    nodes: [limits.max_nodes]Node,
    node_count: usize = 0,
    
    // NEW: Index for O(1) lookups
    // node_index[node_id] → index in nodes array
    // 0xFFFF means not found
    node_index: [limits.max_nodes + 1]u16,  // +1 for node_id 0 placeholder
    
    // Service index
    service_index: [limits.max_services + 1]u16,
};
```

### Lookup Functions

```zig
/// O(1) node lookup
pub fn findNode(world: *const World, node_id: u16) ?*const Node {
    const idx = world.node_index[node_id];
    if (idx == 0xFFFF) return null;
    return &world.nodes[idx];
}

/// O(1) service lookup
pub fn findService(world: *const World, service_id: u16) ?*const ServiceSpec {
    const idx = world.service_index[service_id];
    if (idx == 0xFFFF) return null;
    return &world.services[idx];
}
```

### Update on Add/Remove

```zig
/// Add node with index update
pub fn addNode(world: *World, node: Node) !void {
    // ... existing add logic ...
    
    // NEW: Update index
    world.node_index[node.node_id] = @truncate(world.node_count - 1);
}

/// Remove node with index update
pub fn removeNode(world: *World, node_id: u16) void {
    const idx = world.node_index[node_id];
    // ... existing remove logic ...
    
    // NEW: Clear index
    world.node_index[node_id] = 0xFFFF;
}
```

## Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Node lookup | ~50 ns (64 max) | ~5 ns | **90%** |
| Service lookup | ~100 ns (256 max) | ~5 ns | **95%** |
| Memory overhead | 0 | ~500 bytes | Minimal |

## Dependencies

- None - this is the foundation

## Testing

| Test | Description |
|------|-------------|
| `test "node_index initialized to 0xFFFF"` | Verify index starts empty |
| `test "findNode returns correct node"` | O(1) lookup returns correct node |
| `test "findNode returns null for missing"` | Non-existent node returns null |
| `test "index updated on add"` | Index updates on node add |
| `test "index cleared on remove"` | Index clears on node remove |

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/ecs/world.zig` | Add index arrays, update `findNode`, `findService` |
| `src/core/reducer.zig` | Update reducers to use index lookups |

## Summary

O(1) lookups are the foundational optimization that enables all subsequent improvements. This provides 90-95% faster lookups with minimal memory overhead.