# Feature: Delta CRDT for Reduced Bandwidth

> Status: 🔄 Planned (Feature 24 Phase 5)

## Summary

Implement delta-based CRDT so that gossip messages only contain what's changed, not full state. This provides 99% bandwidth reduction for steady-state gossip.

## Original Ask

Currently gossip sends full state each round (~10KB). For steady-state where only a few things change, this is wasteful. Delta CRDT only sends the changes.

## Implementation

### Delta CRDT Structures

```zig
/// Delta CRDT - tracks only changes since last sync
pub const DeltaNode = struct {
    node_id: u16,
    
    /// Version this delta applies to
    base_version: Timestamp,
    
    /// What's actually changing (not full state)
    delta: DeltaNodeDelta,
};

/// Delta for a node - only changed fields
pub const DeltaNodeDelta = struct {
    /// Which fields changed (bitmask)
    changed: DeltaMask,
    
    /// Changed values (only present for changed fields)
    cpu_mhz: ?u32,
    mem_free_mb: ?u32,
    disk_free_mb: ?u32,
    platform: ?Platform,
    status: ?NodeHealthStatus,
    
    /// Was the node added or removed?
    action: enum { added, updated, removed },
};

/// Delta mask for tracking what changed
pub const DeltaMask = packed struct {
    cpu: bool = false,
    mem: bool = false,
    disk: bool = false,
    platform: bool = false,
    status: bool = false,
    removed: bool = false,
};

/// DeltaService - same pattern for services
pub const DeltaService = struct {
    service_id: u16,
    base_version: Timestamp,
    delta: DeltaServiceDelta,
};
```

### Delta Encode

```zig
/// Generate delta between old and new state
pub fn encodeDelta(old_state: NodeState, new_state: NodeState) DeltaNode {
    var delta: DeltaNodeDelta = undefined;
    
    // Compare each field - only include changes
    if (new_state.cpu_mhz != old_state.cpu_mhz) {
        delta.cpu_mhz = new_state.cpu_mhz;
        delta.changed.cpu = true;
    }
    if (new_state.mem_free_mb != old_state.mem_free_mb) {
        delta.mem_free_mb = new_state.mem_free_mb;
        delta.changed.mem = true;
    }
    // ... only encode changed fields
    
    return .{
        .node_id = new_state.node_id,
        .base_version = old_state.version,
        .delta = delta,
    };
}
```

### Delta Decode/Apply

```zig
/// Apply delta to existing state
pub fn applyDelta(existing: *NodeState, delta: DeltaNodeDelta) void {
    // Only update fields that changed
    if (delta.changed.cpu) existing.cpu_mhz = delta.cpu_mhz.?;
    if (delta.changed.mem) existing.mem_free_mb = delta.mem_free_mb.?;
    if (delta.changed.disk) existing.disk_free_mb = delta.disk_free_mb.?;
    if (delta.changed.platform) existing.platform = delta.platform.?;
    if (delta.changed.status) existing.status = delta.status.?;
    
    // Update version to new HLC
    existing.version = delta.new_version;
}
```

### Gossip with Deltas

```zig
/// Gossip message using deltas instead of full state
pub const GossipMessage = struct {
    /// Node deltas (only what's changed since last sync)
    node_deltas: []DeltaNode,
    
    /// Service deltas
    service_deltas: []DeltaService,
    
    /// Vector clocks - know what peer has without asking
    node_vector: [64]u64,
    service_vector: [256]u64,
    
    /// Is this a full sync request? (peer has nothing)
    full_sync_requested: bool,
};
```

## Comparison

| Aspect | Full State | Delta CRDT |
|--------|------------|------------|
| Steady state bandwidth | ~10KB per sync | ~100 bytes per sync |
| Convergence speed | Full merge | Incremental |
| Complexity | Simple | Medium |
| Recovery | Full state available | Need base state to apply |
| Use case | Initial sync, recovery | Normal operation |

## Performance Impact

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Gossip bandwidth | 10 KB/sync | 100 B/sync | **99%** |
| Network efficiency | Baseline | 100x better | **9900%** |

## Dependencies

- Feature 24d (CRDT Stores) - required (builds on dirty tracking)

## Testing

| Test | Description |
|------|-------------|
| `test "delta encode captures changes"` | Only changed fields in delta |
| `test "delta apply updates correctly"` | Delta applied properly |
| `test "delta merge converges"` | Multiple deltas converge |

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/ecs/delta_crdt.zig` | NEW FILE - Delta CRDT encoding/decoding |
| `src/net/gossip.zig` | Update gossip to use deltas |

## Summary

Delta CRDT provides 99% bandwidth reduction for steady-state gossip. This is critical for scaling to hundreds of nodes.