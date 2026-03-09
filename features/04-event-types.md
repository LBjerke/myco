# Feature: Typed Event Definitions

## Status: ✅ Complete

## Original Ask

Define typed event structures for the state machine, based on proposal 01-overview.md:

> Reducers take `(world, input) -> (world', effects)`.
> Reducers never perform I/O; they only return a list of effects.

And proposal 02-services-and-interfaces.md:

> Every ingress mutation must choose whether it is durable (WAL) or ephemeral.
> Durable changes include service specs, replica counts, placement overrides.

## Where Code Was Added/Changed

### Files Created

| File | Purpose |
|------|---------|
| `src/core/event.zig` | Event kinds and payload types |

### Code Added

```zig
// src/core/event.zig

/// Event kinds that can occur in the system.
pub const EventKind = enum(u8) {
    node_join,
    node_leave,
    service_create,
    service_delete,
    service_scale,
    placement_claim,
    placement_release,
};

/// A typed event with timestamp.
pub fn Event(comptime T: type) type {
    return struct {
        kind: EventKind,
        timestamp: Timestamp,
        payload: T,
    };
}

/// Event payloads
pub const NodeJoinPayload = struct { node_id: u16 };
pub const ServiceCreatePayload = struct { 
    service_id: u16, 
    name: []const u8, 
    replicas: u8 
};
```

## Architecture

```
┌─────────────────────────────────────┐
│           Event System              │
├─────────────────────────────────────┤
│  EventKind (enum u8)                │
│  ├── node_join                      │
│  ├── node_leave                     │
│  ├── service_create                 │
│  ├── service_delete                 │
│  ├── service_scale                  │
│  ├── placement_claim                 │
│  └── placement_release              │
├─────────────────────────────────────┤
│  Payload Types                      │
│  ├── NodeJoinPayload                │
│  └── ServiceCreatePayload           │
├─────────────────────────────────────┤
│  Event(T) = Kind + Timestamp + T   │
└─────────────────────────────────────┘
```

### Event Flow (Future)

```
Events → WAL (durable) → Reducer → Effects
```

## Testing

- Build verification: `zig build` passes
- EventKind enum has 7 variants
- Generic Event(T) type works correctly

## Summary

Minimal event system with:
- 7 event kinds covering node lifecycle, service management, and placement
- Generic Event(T) wrapper with timestamp
- Payload types for node_join and service_create

More event kinds and payloads will be added as features are implemented.
