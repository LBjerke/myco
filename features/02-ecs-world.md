# Feature: ECS World (Entity Component System)

## Status: ✅ Complete

## Original Ask

Create the core ECS world structure to hold all component tables. Based on proposal 01-overview.md:

> The "world" is a set of fixed-capacity, columnar tables for components.
> Entities are just IDs: `NodeId`, `ServiceId`, `ReplicaKey`.

## Where Code Was Added/Changed

### Files Created

| File | Purpose |
|------|---------|
| `src/ecs/world.zig` | ECS world with Node and ServiceSpec components |

### Code Added

```zig
// src/ecs/world.zig

/// Node entity representation.
pub const Node = struct {
    id: u16,
    alive: bool,
};

/// Service specification.
pub const ServiceSpec = struct {
    id: u16,
    name: []const u8,
    replicas: u8,
};

/// The ECS World - holds all component tables.
pub const World = struct {
    nodes: [limits.MAX_NODES]Node,
    node_count: usize = 0,
    services: [limits.MAX_SERVICES]ServiceSpec,
    service_count: usize = 0,

    pub fn init() World { ... }
};
```

## Architecture

The ECS world follows the proposal's architecture:

```
┌─────────────────────────────────────┐
│           ECS World                 │
├─────────────────────────────────────┤
│  Node[]          ServiceSpec[]      │
│  [id, alive]     [id, name, replicas]│
│                                     │
│  Fixed-capacity tables (SoA)        │
└─────────────────────────────────────┘
```

- **SoA (Structure of Arrays)**: Components stored in fixed arrays
- **Bounded**: Respects MAX_NODES and MAX_SERVICES limits
- **Simple**: No indices or dirty tracking yet (future feature)

## Testing

- Build verification: `zig build` passes
- World.init() called successfully in main.zig

## Summary

Basic ECS world structure created with:
- Node component (id, alive flag)
- ServiceSpec component (id, name, replicas)
- Fixed-capacity arrays bounded by limits

This is intentionally minimal - expansion to full component table design will come in Phase 2.
