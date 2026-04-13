# Feature: Disaster Recovery - Snapshot and Services as Code

> Status: 🔄 Planned

## Summary

Implement comprehensive disaster recovery for Myco that leverages services-as-code principles and cluster-wide snapshots to enable fast recovery from any failure scenario, including full cluster loss.

## Use Case

Production deployments need reliable disaster recovery. Myco achieves this through:
- Services defined as code (Git as source of truth)
- Cluster-wide snapshots for point-in-time recovery
- Gossip-based peer recovery for fast operational recovery
- Shard-aware backup for sharded WAL deployments

## Problem Statement

When a cluster experiences disaster (hardware failure, data corruption, full site loss), operators need to:
1. Recover services as quickly as possible
2. Restore cluster state to a known good point
3. Ensure no permanent data loss for critical services

Traditional approaches require complex external databases or accept eventual data loss. Myco's approach leverages its distributed design for multiple recovery paths.

## Architecture

### Recovery Layers

Myco implements multiple recovery layers, each providing different guarantees:

```
┌─────────────────────────────────────────────────────────────┐
│  Recovery Layer Priority                                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Layer 1: Services as Code (IaC)                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ - All service definitions in Git                   │   │
│  │ - Can always re-apply manifests                    │   │
│  │ - This is the TRUE source of truth                │   │
│  │ - Survives complete cluster loss                   │   │
│  └─────────────────────────────────────────────────────┘   │
│  Recovery Time: Minutes (manual re-apply)                 │
│  Data Loss: None (code is source)                         │
│                                                             │
│  Layer 2: Cluster Snapshots                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ - Periodic export of cluster state                 │   │
│  │ - All shards, all services, all placements        │   │
│  │ - Stored externally (S3, local file, etc.)        │   │
│  │ - Point-in-time recovery possible                 │   │
│  └─────────────────────────────────────────────────────┘   │
│  Recovery Time: Seconds to minutes                         │
│  Data Loss: Depends on snapshot frequency                  │
│                                                             │
│  Layer 3: Gossip (Peer Recovery)                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ - Any surviving node has cluster state in memory  │   │
│  │ - New nodes gossip to learn current state         │   │
│  │ - No external storage needed                      │   │
│  └─────────────────────────────────────────────────────┘   │
│  Recovery Time: Seconds                                    │
│  Data Loss: All in-memory state if no survivors            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Services as Code

The primary recovery mechanism relies on services being defined as code:

```
┌─────────────────────────────────────────────────────────────┐
│  Services as Code Workflow                                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  // User defines service                                    │
│  service.yaml:                                             │
│    name: web-frontend                                       │
│    replicas: 3                                              │
│    image: nginx:v1.23                                       │
│    placement: region-us-east                                │
│                                                             │
│  // Commit to Git                                           │
│  git add service.yaml                                       │
│  git commit -m "Add web-frontend service"                   │
│                                                             │
│  // Deploy to cluster                                       │
│  myco deploy -f service.yaml                               │
│                                                             │
│  // Cluster stores in CRDT, Git is source of truth         │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Recovery after full cluster loss:
  1. Bring up new Myco cluster nodes
  2. myco deploy -f service.yaml (from Git)
  3. Services restored - no data loss!

Key insight: If it's not in Git, it doesn't exist.
```

### Cluster Snapshots

Periodic snapshots provide point-in-time recovery capability:

```zig
/// Snapshot - complete export of cluster state
pub const ClusterSnapshot = struct {
    /// Timestamp of snapshot
    timestamp: Timestamp,
    
    /// HLC version for consistency
    version: Timestamp,
    
    /// All node states at time of snapshot
    nodes: []NodeState,
    
    /// All service specifications
    services: []ServiceSpec,
    
    /// All service placements
    placements: []ServicePlacement,
    
    /// Shard ownership at time of snapshot
    shard_map: ShardMap,
    
    /// Generate snapshot from current cluster state
    pub fn create(world: *World) ClusterSnapshot {
        return .{
            .timestamp = hlc.now(),
            .version = world.state_version,
            .nodes = world.node_store.dumpAll(),
            .services = world.service_store.dumpAll(),
            .placements = world.placement_store.dumpAll(),
            .shard_map = world.shard_map,
        };
    }
    
    /// Restore snapshot to cluster
    pub fn restore(world: *World, snapshot: ClusterSnapshot) void {
        // Clear current state
        world.reset();
        
        // Restore nodes
        for (snapshot.nodes) |node| {
            world.node_store.restore(node);
        }
        
        // Restore services
        for (snapshot.services) |svc| {
            world.service_store.restore(svc);
        }
        
        // Restore placements
        for (snapshot.placements) |placement| {
            world.placement_store.restore(placement);
        }
        
        // Restore shard ownership
        world.shard_map = snapshot.shard_map;
    }
    
    /// Serialize for storage
    pub fn serialize(self: ClusterSnapshot, writer: anytype) !void {
        try writer.writeStruct(self.timestamp);
        try writer.writeStruct(self.version);
        try writer.writeArray(self.nodes);
        try writer.writeArray(self.services);
        try writer.writeArray(self.placements);
        try writer.writeStruct(self.shard_map);
    }
    
    /// Deserialize from storage
    pub fn deserialize(reader: anytype) !ClusterSnapshot {
        return .{
            .timestamp = try reader.readStruct(Timestamp),
            .version = try reader.readStruct(Timestamp),
            .nodes = try reader.readArray([]NodeState),
            .services = try reader.readArray([]ServiceSpec),
            .placements = try reader.readArray([]ServicePlacement),
            .shard_map = try reader.readStruct(ShardMap),
        };
    }
};
```

### Snapshot Commands

```zig
/// CLI commands for snapshot management
pub const SnapshotCommands = struct {
    /// Create a snapshot
    pub fn create(path: []const u8) !ClusterSnapshot {
        const world = getWorld();
        const snapshot = ClusterSnapshot.create(&world);
        
        // Serialize and write to path
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        try snapshot.serialize(file.writer());
        
        return snapshot;
    }
    
    /// Restore from snapshot
    pub fn restore(path: []const u8) !void {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const snapshot = try ClusterSnapshot.deserialize(file.reader());
        
        var world = getWorld();
        snapshot.restore(&world);
        
        std.debug.print("Restored {} nodes, {} services from snapshot\n", .{
            snapshot.nodes.len,
            snapshot.services.len,
        });
    }
    
    /// List available snapshots
    pub fn list(dir: []const u8) !void {
        var iter = try std.fs.cwd().openDir(dir, .{});
        defer iter.close();
        
        var count: usize = 0;
        while (iter.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".snapshot")) {
                std.debug.print("  {s}\n", .{entry.name});
                count += 1;
            }
        }
        
        std.debug.print("Found {} snapshots\n", .{count});
    }
};
```

### Gossip-Based Recovery (Peer Recovery)

When at least one node survives, gossip enables fast recovery:

```
┌─────────────────────────────────────────────────────────────┐
│  Scenario: 3-node cluster, 1 node survives                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  BEFORE DISASTER:                                          │
│  ┌────────┐  ┌────────┐  ┌────────┐                       │
│  │ Node A │  │ Node B │  │ Node C │                       │
│  │ Shard0 │  │ Shard1 │  │ Shard2 │                      │
│  │  FULL  │  │  FULL  │  │  FULL  │                       │
│  └────────┘  └────────┘  └────────┘                       │
│                                                             │
│  DISASTER: Nodes B and C destroyed                        │
│                                                             │
│  AFTER (Node A survives):                                 │
│  ┌────────┐                                                │
│  │ Node A │  ← Has in-memory state for ALL shards          │
│  │ Shard0 │     (gossiped to it during operation)         │
│  │  FULL  │                                                │
│  └────────┘                                                │
│                                                             │
│  Node A still has:                                          │
│  - All nodes (was propagated via gossip)                   │
│  - All services (was propagated via gossip)                 │
│  - All placements (was propagated via gossip)               │
│                                                             │
│  RECOVERY: New nodes connect to Node A                     │
│  1. New Node B starts                                      │
│  2. Connects to Node A                                     │
│  3. Requests full state                                    │
│  4. Node A sends complete cluster state                    │
│  5. Node B merges via CRDT                                 │
│  6. Both have full state                                   │
│                                                             │
│  Time to recovery: Seconds                                 │
│  Data loss: Only in-memory changes since last WAL flush    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Shard-Aware Recovery (For Sharded WAL)

When using sharded WAL, snapshots must capture shard distribution:

```zig
/// Shard map - tracks which node owns which shard
pub const ShardMap = struct {
    /// Shard ownership: shard_id -> node_id
    ownership: [max_shards]u16,
    
    /// Number of shards
    shard_count: usize,
    
    /// Get owner of a service
    pub fn getOwner(self: *const ShardMap, service_id: u16) u16 {
        const shard_id = service_id % self.shard_count;
        return self.ownership[shard_id];
    }
    
    /// Snapshot must include shard map for correct recovery
    pub fn includeInSnapshot(self: *const ShardMap) Snapshot {
        return .{
            .ownership = self.ownership,
            .shard_count = self.shard_count,
        };
    }
};

/// Recovery with sharded WAL:
/// 1. Load snapshot (includes shard map)
/// 2. Each node loads its shard from snapshot
/// 3. Nodes gossip to reconcile state
/// 4. Full cluster restored
```

## Disaster Scenarios

| Scenario | Recovery Path | Time | Data Loss |
|----------|---------------|------|-----------|
| Full cluster loss | Services as code (Git) | Minutes | None |
| All WAL corrupted | Restore from snapshot | Seconds | Snapshot age |
| No snapshot | Services as code only | Minutes | State (not specs) |
| 1+ nodes survive | Gossip from survivors | Seconds | WAL-only |
| Hardware failure | Gossip + WAL replay | Seconds | WAL delay |
| Region loss | Restore from snapshot | Minutes | Snapshot age |

## Configuration

### Snapshot Scheduling

```zig
/// Snapshot configuration
pub const SnapshotConfig = struct {
    /// Enable automatic snapshots
    enabled: bool = true,
    
    /// Interval between snapshots
    interval_ms: u64 = 3600000, // 1 hour
    
    /// Retain last N snapshots
    retain_count: u32 = 24,
    
    /// Storage backend (file, S3, etc)
    backend: StorageBackend,
    
    /// Compression for snapshots
    compress: bool = true,
};
```

### Storage Backends

```zig
/// Pluggable storage backends
pub const StorageBackend = union(enum) {
    /// Local filesystem
    local: struct {
        path: []const u8,
    },
    
    /// S3-compatible object storage
    s3: struct {
        bucket: []const u8,
        region: []const u8,
        prefix: []const u8,
    },
    
    /// Custom handler for other backends
    custom: fn(path: []const u8, data: []u8) void,
};
```

## Implementation Plan

### Phase 1: Basic Snapshots
- Snapshot creation command
- Snapshot restore command  
- File-based storage
- Basic snapshot tests

### Phase 2: Services as Code Integration
- Git-backed service definitions
- Deploy from file functionality
- Integration with service spec

### Phase 3: Automated Snapshots
- Background snapshot scheduler
- Snapshot rotation/cleanup
- S3 storage backend

### Phase 4: Shard-Aware Recovery
- Shard map in snapshots
- Per-shard recovery
- Gossip + snapshot hybrid recovery

## Testing

### Unit Tests

| Test | Description |
|------|-------------|
| `test "snapshot create captures all state"` | Verify complete state export |
| `test "snapshot restore rebuilds cluster"` | Verify full restore |
| `test "snapshot serialize/deserialize"` | Round-trip works |
| `test "shard map included in snapshot"` | Shard recovery works |

### Integration Tests

| Test | Description |
|------|-------------|
| `test "recover from full cluster loss"` | Re-apply services from code |
| `test "recover from single surviving node"` | Gossip recovery |
| `test "recover from snapshot"` | Point-in-time restore |
| `test "sharded WAL recovery"` | Recover from snapshot with shards |

## Where Code Was Added/Changed

| File | Changes |
|------|---------|
| `src/db/snapshot.zig` | NEW FILE - Snapshot creation, restore, storage |
| `src/cli/snapshot.zig` | NEW FILE - CLI commands for snapshot management |
| `src/core/event.zig` | Add service definition serialization |
| `src/lib.zig` | Export Snapshot, SnapshotConfig |
| `src/main.zig` | Add `snapshot` subcommand |

## Summary

Myco's disaster recovery approach leverages multiple layers:

1. **Services as Code** - Git is the true source of truth; services can always be re-deployed
2. **Cluster Snapshots** - Point-in-time recovery from external storage
3. **Gossip Recovery** - Fast recovery from surviving nodes without external storage
4. **Shard-Aware Backup** - Proper handling for sharded WAL deployments

This provides recovery options for every failure scenario while maintaining Myco's core philosophy of simplicity and no external dependencies for edge deployments.