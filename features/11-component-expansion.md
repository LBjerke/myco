# Feature: ECS Component Expansion

**Status**: ✅ Complete

## Original Ask

Expand the ECS component tables with more data types as described in the architecture proposal, including NodeMeta, ServiceRuntime, and ServicePlacement.

## Why This Matters

The original ECS World only had basic components:
- `Node` - just id and alive status
- `NodeHealth` - health tracking
- `ServiceSpec` - minimal service definition

This was insufficient for a real distributed system. The proposal specified additional components needed for:
- **Placement decisions** - Which node should run which service?
- **Capacity planning** - How much CPU/memory is available?
- **Runtime tracking** - Is the service actually running?

## Where Code Was Added/Changed

| File | Action | Description |
|------|--------|-------------|
| `src/ecs/world.zig` | Modified | Expanded from 3 to 6 component types |

## New Components

### 1. NodeMeta (replicated)
```zig
pub const NodeMeta = struct {
    node_id: u16,
    cpu_mhz: u32,          // Available CPU
    mem_free_mb: u32,       // Available memory
    disk_free_mb: u32,      // Available disk
    platform: Platform,     // linux_arm64, darwin_x64, etc.
    version: Timestamp,      // HLC for CRDT merge
    last_seen_ms: u64,      // For TTL/heartbeat
    active: bool,
};
```
**Purpose**: Replicated metadata for placement decisions.

### 2. ServiceSpec Expansion (replicated)
```zig
pub const ServiceSpec = struct {
    service_id: u16,
    name: []const u8,
    replicas: u8,
    spec_hash: u64,         // Hash of full spec
    platform_mask: u16,     // Platform requirements
    constraints_hash: u64,  // Placement constraints
    version: Timestamp,     // HLC for CRDT merge
    active: bool,
};
```
**Purpose**: Replicated summary (small enough for gossip).

### 3. ServiceRuntime (local only)
```zig
pub const ServiceRuntime = struct {
    service_id: u16,
    running: bool,
    unit_name: []const u8,
    last_start_ms: u64,
    last_exit_code: u8,
    backoff_level: u8,
    active: bool,
};
```
**Purpose**: Local runtime state (not replicated via gossip).

### 4. ServicePlacement (replicated)
```zig
pub const ServicePlacement = struct {
    service_id: u16,
    replica_id: u8,
    node_id: u16,
    lease_epoch: u32,
    expires_at_ms: u64,
    score: i16,
    version: Timestamp,
    active: bool,
};
```
**Purpose**: Which node owns which replica (CRDT-based).

### 5. Platform Enum
```zig
pub const Platform = enum(u8) {
    linux_x64 = 1,
    linux_arm64 = 2,
    linux_arm = 3,
    darwin_x64 = 4,
    darwin_arm64 = 5,
    unknown = 0,
};
```

## World Structure

```zig
pub const World = struct {
    // Node components
    nodes: [64]Node,
    node_metas: [64]NodeMeta,      // NEW
    node_health: [64]NodeHealth,
    
    // Service components
    services: [256]ServiceSpec,
    service_runtimes: [256]ServiceRuntime,  // NEW
    placements: [2048]ServicePlacement,    // NEW (256*8)
};
```

## Helper Methods Added

- `World.findNode(id)` - Find node by ID
- `World.findNodeMeta(id)` - Find metadata by node ID
- `World.findService(id)` - Find service by ID
- `World.findPlacement(service_id, replica_id)` - Find specific placement
- `World.findPlacementsForService(id)` - Get all placements for a service

## Tests Added

- `test "NodeMeta default values"`
- `test "ServiceSpec default values"`
- `test "ServiceRuntime default values"`
- `test "ServicePlacement default values"`
- `test "Platform enum values"`
- `test "World.findNode returns null for missing node"`
- `test "World.findService returns null for missing service"`
- `test "World.findPlacement returns null for missing placement"`

## Component Categories

| Component | Replicated | Purpose |
|-----------|------------|---------|
| Node | No | Basic identity |
| NodeMeta | ✅ Yes | Capacity/placement |
| NodeHealth | No | Local health |
| ServiceSpec | ✅ Yes | Service definition |
| ServiceRuntime | No | Local runtime |
| ServicePlacement | ✅ Yes |Replica ownership |

This separation ensures:
- Gossip packets stay small (only replicated data)
- Local state doesn't pollute the network
- Placement decisions have all necessary info

## Summary

Expanded ECS components from 3 to 6 types:

1. **Node** - Basic node identity (already existed)
2. **NodeMeta** - NEW: Capacity info for placement
3. **NodeHealth** - Local health (already existed)
4. **ServiceSpec** - Expanded with hashes and versioning
5. **ServiceRuntime** - NEW: Local runtime state
6. **ServicePlacement** - NEW: Replica ownership via CRDT

All tests pass. The ECS World is now ready for the networking phase.
