# Feature: Sharded WAL for Cluster Scale

> Status: 🔄 Future / Research

## Summary

Implement sharded Write-Ahead Log (WAL) to enable Myco to scale beyond single-node WAL limitations. Each node owns and writes to its own shard, with gossip handling cross-shard synchronization. This allows scaling to 500+ nodes without requiring an external database.

## Problem

At 500+ nodes with high event rates (100K+ events/sec), a single WAL becomes a bottleneck:
- All writes go to one file
- Disk I/O becomes serialized
- Single point of contention

Current architecture (Feature 24) uses a single mmap'd WAL which works for edge but not for scale.

## Use Case

Clusters that need to scale beyond 500 nodes while maintaining:
- No external database dependency
- Local writes only (no cross-node locking)
- Gossip-based state synchronization
- Full disaster recovery capability

## Architecture

### Sharding Strategy

```
┌─────────────────────────────────────────────────────────────┐
│           Shard Distribution by Service ID                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Services are distributed across shards:                   │
│                                                             │
│  Service ID % Shard Count = Shard ID                       │
│                                                             │
│  Example: 3 shards, 1000 services                           │
│  ─────────────────────────────────────────────────────────  │
│  Services 0-332    →  Shard 0 (Node A)                     │
│  Services 333-665  →  Shard 1 (Node B)                     │
│  Services 666-999  →  Shard 2 (Node C)                     │
│                                                             │
│  Key: Each shard is WRITTEN only by its owner              │
│       But READ/BROADCAST via gossip to all nodes           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Shard Ownership

```
┌─────────────────────────────────────────────────────────────┐
│  Cluster: 3 nodes, 3 shards                                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Node A (192.168.1.10):                                      │
│  ├── Owns: Shard 0                                          │
│  ├── Writes: Services 0-332                                 │
│  ├── Local WAL: shard0.wal                                  │
│  └── State: Has FULL cluster state (gossiped)               │
│                                                             │
│  Node B (192.168.1.11):                                     │
│  ├── Owns: Shard 1                                         │
│  ├── Writes: Services 333-665                               │
│  ├── Local WAL: shard1.wal                                 │
│  └── State: Has FULL cluster state (gossiped)               │
│                                                             │
│  Node C (192.168.1.12):                                     │
│  ├── Owns: Shard 2                                         │
│  ├── Writes: Services 666-999                              │
│  ├── Local WAL: shard2.wal                                 │
│  └── State: Has FULL cluster state (gossiped)              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Write Path (No Locking)

```
┌─────────────────────────────────────────────────────────────┐
│  Write Path: Service Deploy Event                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Client sends to any node (load balancer)               │
│                                                             │
│  2. Receiving node determines shard:                        │
│     shard = service_id % shard_count                      │
│                                                             │
│  3. Node forwards to shard owner:                          │
│     if (shard == my_shard) {                               │
│         // Write locally - no locking!                     │
│         wal.append(event);                                 │
│     } else {                                               │
│         // Forward to owner                                │
│         network.sendTo(owner, event);                      │
│     }                                                      │
│                                                             │
│  4. Shard owner appends to local WAL:                      │
│     // This is LOCAL - no cross-node coordination          │
│     shard_wal.write(event);                                │
│                                                             │
│  5. Event is gossiped to all other nodes:                  │
│     // Everyone gets the update                             │
│     gossip.broadcast(event);                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### State Synchronization (Gossip)

```
┌─────────────────────────────────────────────────────────────┐
│  Gossip Path: Node State Merge                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Each node maintains FULL cluster state in memory:         │
│  (not just their own shard)                                 │
│                                                             │
│  Node A receives gossip:                                     │
│  ├── Has Shard 0 (local, from WAL)                        │
│  ├── Has Shard 1 (from gossip of Node B)                  │
│  ├── Has Shard 2 (from gossip of Node C)                  │
│                                                             │
│  Merge via CRDT:                                           │
│  - Compare HLC timestamps                                  │
│  - Newer version wins                                       │
│  - Result: Full cluster state on each node                 │
│                                                             │
│  Key insight:                                              │
│  - WAL is for DURABILITY (replay after crash)             │
│  - Gossip is for STATE (keep all nodes in sync)           │
│  - Separation of concerns!                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Shard Rebalancing

When nodes join or leave, shards must be rebalanced:

```zig
/// Shard rebalancing event
pub const ShardRebalance = struct {
    /// New shard ownership map
    shard_map: ShardMap,
    
    /// Affected shards
    rebalanced_shards: []u16,
    
    /// Transfer mode: copy or move
    transfer_mode: enum { copy, move },
};

/// Rebalancing process:
/// 1. Consensus on new shard map (gossip)
/// 2. Old owner exports its shard data
/// 3. New owner imports shard data
/// 4. Clients redirect to new owner
/// 5. Old owner garbage collects old shard
```

## Implementation Details

### Shard Configuration

```zig
/// Shard configuration
pub const ShardConfig = struct {
    /// Number of shards in cluster
    /// Must be >= node count for even distribution
    shard_count: usize,
    
    /// Shard to node mapping
    shard_owners: []u16,
    
    /// Get owner of a service
    pub fn getOwner(config: *const ShardConfig, service_id: u16) u16 {
        const shard = service_id % config.shard_count;
        return config.shard_owners[shard];
    }
    
    /// Check if node owns a shard
    pub fn ownsShard(config: *const ShardConfig, node_id: u16, shard: u16) bool {
        return config.shard_owners[shard] == node_id;
    }
};
```

### Sharded WAL

```zig
/// Sharded WAL - multiple independent WAL files
pub const ShardedWal = struct {
    /// Array of WAL instances (one per shard)
    shards: []Wal,
    
    /// Shard count
    shard_count: usize,
    
    /// My node ID (for ownership determination)
    my_node_id: u16,
    
    /// Initialize sharded WAL
    pub fn init(shard_count: usize, node_id: u16) !ShardedWal {
        var shards = try allocator.alloc(Wal, shard_count);
        
        for (0..shard_count) |i| {
            shards[i] = try Wal.init("shard-{}.wal", i);
        }
        
        return .{
            .shards = shards,
            .shard_count = shard_count,
            .my_node_id = node_id,
        };
    }
    
    /// Write event to appropriate shard
    pub fn append(wal: *ShardedWal, event: Event) !void {
        const shard = event.service_id % wal.shard_count;
        
        // Only owner writes - no locking needed!
        if (wal.shard_owners[shard] == wal.my_node_id) {
            try wal.shards[shard].append(event);
        }
    }
    
    /// Get local shard for reading
    pub fn getLocalShard(wal: *ShardedWal, shard: u16) *Wal {
        return &wal.shards[shard];
    }
};
```

### Shard-Aware Gossip

```zig
/// Gossip message includes shard ownership for routing
pub const ShardAwareGossip = struct {
    /// Current shard map (for routing)
    shard_map: ShardMap,
    
    /// For forward routing: which node owns a shard?
    pub fn getShardOwner(gossip: *const ShardAwareGossip, shard: u16) u16 {
        return gossip.shard_map.shard_owners[shard];
    }
    
    /// For gossip: what does each peer have?
    pub fn getPeerState(gossip: *const ShardAwareGossip, peer: u16) ShardState {
        // Return what this peer has in each shard
    }
};
```

## Comparison: Sharded vs Single WAL

| Aspect | Single WAL | Sharded WAL | Improvement |
|--------|------------|-------------|-------------|
| **Max nodes** | ~100 | ~1000+ | 10x |
| **Write throughput** | 10K events/s | 100K+ events/s | 10x |
| **Lock contention** | High (single file) | None (local only) | ✓ |
| **Complexity** | Low | Medium | - |
| **Rebalancing** | N/A | Required | - |
| **Recovery** | Simple | Shard-aware | - |

## Disaster Recovery with Sharded WAL

### Scenario: One Shard Owner Dies

```
Before:
- Node A owns Shard 0
- Node B owns Shard 1  
- Node C owns Shard 2

Disaster:
- Node B dies

Recovery:
1. Other nodes detect Node B is down
2. Gossip propagates "Shard 1 has no owner"
3. New Node B' joins
4. Gets assigned Shard 1
5. Reconstructs Shard 1 from:
   a. Local WAL if storage survived
   b. Snapshot restore
   c. Gossip from other nodes (memory state)
6. Cluster continues
```

### Backup Strategy

Each shard owner maintains local backup:

```zig
/// Shard backup - periodic snapshot of local shard
pub const ShardBackup = struct {
    /// Snapshot shard state to file
    pub fn snapshot(shard_id: u16, path: []const u8) !void {
        const wal = getShardedWal();
        const snapshot = try wal.shards[shard_id].createSnapshot();
        
        try saveToFile(path, snapshot);
    }
    
    /// Restore shard from backup
    pub fn restore(shard_id: u16, path: []const u8) !void {
        const snapshot = try loadFromFile(path);
        
        const wal = getShardedWal();
        try wal.shards[shard_id].restore(snapshot);
    }
};
```

## Open Questions / Research Needed

1. **Shard count**: How to determine optimal shard count?
   - Too few: not enough parallelism
   - Too many: coordination overhead

2. **Rebalancing**: How to handle shard transfer without downtime?
   - Copy vs move strategies
   - Client redirect timing

3. **Cross-shard transactions**: How to handle services that span shards?
   - Not supported (service must fit in one shard)
   - Design constraint

4. **Failure detection**: How to detect shard owner failure quickly?
   - Use existing gossip mechanism
   - Add heartbeat for shard ownership

## When This Becomes Relevant

| Cluster Size | Recommendation |
|--------------|----------------|
| 1-100 nodes | Single WAL (Feature 24) sufficient |
| 100-500 nodes | Single WAL + optimize gossip first |
| 500-1000 nodes | Sharded WAL needed |
| 1000+ nodes | Consider external DB instead |

## Related Features

- Feature 24: ECS Optimization (single WAL)
- Feature 27: Disaster Recovery (snapshots work with sharded WAL)
- Feature 26: Myco Edge (doesn't need sharding - edge scale)

## Summary

Sharded WAL enables Myco to scale beyond single-node WAL limitations:
- **Local writes only** - no cross-node locking
- **Gossip for state** - keeps all nodes synchronized
- **Shard ownership** - clear responsibility
- **Recovery** - each shard can be restored independently

This maintains Myco's core philosophy (no external DB, simple code) while enabling 500-1000 node clusters.