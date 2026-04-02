# Greenfield Architecture: ECS-CRDT + WAL

This document defines a from-scratch (greenfield) architecture for Myco using ECS + CRDT semantics with WAL durability. It is written to preserve the original constraints of the project while removing legacy compatibility concerns.

## Goals and Constraints (Inherited from the current project)

- Fixed packet size (1024 bytes) with compact, efficient gossip payloads.
- Low allocation and predictable memory usage (fixed-size tables and bounded arrays).
- Deterministic identity (especially for simulations).
- HLC-based LWW ordering for replicated state.
- WAL durability with CRC checks and replay on boot.
- Offline-friendly operation (local state is authoritative).
- Small binary footprint (avoid heavyweight DB dependencies).

## High-Level Architecture

```text
+---------------------------+
| CLI / main                |
| - parse args/env          |
+-------------+-------------+
              |
              v
+---------------------------+
| ECS World (SoA storage)   |
| - NodeMeta/Identity       |
| - ServiceSpec/Version     |
| - ServicePlacement        |
| - ServiceRuntime          |
+-------------+-------------+
              |
              v
+---------------------------+     +------------------+
| Systems (tick loop)       |<--->| Gossip I/O       |
| - WalReplay (boot)         |     | Packet size=1024|
| - CrdtMerge                |     | Digest deltas   |
| - Placement/Leases         |     +------------------+
| - Reconcile (systemd)      |
+------+------+-------------+
       |      |
       v      v
+------+----+ +--------------------+
| WAL v2  |  | systemd runtime     |
| typed   |  | apply/reconcile     |
| CRC     |  +--------------------+
+---------+
```

## Entities and Components

Entities:
- Node
- Service
- ServiceReplica

Components (replicated unless noted):
- NodeMeta (CRDT LWW): cpu_free, mem_free, disk_free, platform, last_seen_ms, version (HLC).
- NodeIdentity (local/replicated as needed): node_id, public key, seed.
- ServiceSpec (CRDT LWW): spec_hash, replicas, platform_mask, version (HLC).
- ServicePlacement (CRDT register): service_id, replica_id, node_id, lease_epoch, expires_at_ms, score, basis_meta_version, version (HLC).
- ServiceRuntime (local): systemd state, last_change_ms, last_exit_code.

Notes:
- Service specs can be large; the on-wire payload should carry a hash and version, with a fetch path for full specs.
- NodeMeta is high churn; keep it replicated but not necessarily WAL-durable unless required.

## CRDT Semantics

- NodeMeta and ServiceSpec: LWW using HLC ordering.
- ServicePlacement: register with tie-break rules:
  1) higher lease_epoch
  2) newer HLC
  3) higher score
  4) lower node_id (deterministic)

## WAL v2 Entry Types

Typed entries with versioned header and CRC:
- PutServiceSpec(service_id, spec_hash, replicas, platform_mask, hlc)
- SetPlacement(service_id, replica_id, node_id, lease_epoch, expires_at_ms, score, basis_meta_version, hlc)
- UpdateNodeMeta(node_id, meta, hlc) (optional for durability)
- ReleasePlacement(service_id, replica_id, node_id, reason, hlc) (optional)

Replay is deterministic: apply entries in log order to rebuild ECS state.

## Systems (Tick Loop)

1) ReplaySystem (boot only)
- Replays WAL v2 into ECS components.

2) CrdtMergeSystem
- Applies incoming deltas to local components with CRDT merge rules.

3) PlacementScoringSystem
- Computes deterministic scores for each replica across eligible nodes.
- Uses NodeMeta and ServiceSpec constraints.

4) PlacementClaimSystem
- If self is best and placement is missing/expired or clearly worse, append SetPlacement to WAL and update CRDT.
- Uses leases and hysteresis to reduce thrash.

5) ReconcileSystem
- Starts/stops systemd units so runtime matches placement for this node.

6) GossipSystem
- Encodes per-component deltas into 1024-byte packets.
- Sends deltas plus periodic samples to aid convergence.

## Module Layout (Greenfield)

```text
src/
  main.zig                     # CLI entry + daemon bootstrap
  limits.zig                   # fixed capacities; used by ECS + gossip
  packet.zig                   # 1024-byte packet layout
  ecs/
    world.zig                  # entity allocator + component storage
    components.zig             # NodeMeta, ServiceSpec, Placement, Runtime
    systems/
      replay.zig               # WAL replay into ECS
      gossip.zig               # encode/decode deltas
      merge.zig                # CRDT merge logic
      placement.zig            # scoring + claim + lease renewal
      reconcile.zig            # systemd desired vs actual
  sync/
    hlc.zig                    # HLC packing + ordering
    crdt.zig                   # LWW + register merge helpers
  db/
    wal.zig                    # WAL append/replay core
    wal_types.zig              # typed entry schemas
  net/
    handshake.zig              # identity + keying
    transport.zig              # packet transport
  runtime/
    systemd.zig                # unit generation + apply
  gossip/
    codec.zig                  # digest encoding
  schema/
    service.zig                # on-wire service schema (compact)
tests/
  wal_v2.zig
  placement.zig
  rebalance.zig
  gossip_roundtrip.zig
  simulation.zig
```

## Minimal Scaffolding (Illustrative)

`src/ecs/world.zig`

```zig
const std = @import("std");
const comps = @import("components.zig");

pub const Entity = u32;

pub const World = struct {
    next: Entity = 1,
    node_meta: comps.Table(comps.NodeMeta),
    service_spec: comps.Table(comps.ServiceSpec),
    service_placement: comps.Table(comps.ServicePlacement),
    service_runtime: comps.Table(comps.ServiceRuntime),

    pub fn init() World {
        return .{
            .node_meta = comps.Table(comps.NodeMeta).init(),
            .service_spec = comps.Table(comps.ServiceSpec).init(),
            .service_placement = comps.Table(comps.ServicePlacement).init(),
            .service_runtime = comps.Table(comps.ServiceRuntime).init(),
        };
    }

    pub fn newEntity(self: *World) Entity {
        const id = self.next;
        self.next += 1;
        return id;
    }
};
```

`src/ecs/components.zig`

```zig
const limits = @import("../limits.zig");

pub fn Table(comptime T: type) type {
    return struct {
        items: [limits.MAX_ENTITIES]T = undefined,
        active: [limits.MAX_ENTITIES]bool = [_]bool{false} ** limits.MAX_ENTITIES,

        pub fn init() @This() { return .{}; }
        pub fn put(self: *@This(), id: u32, v: T) void {
            self.items[id] = v;
            self.active[id] = true;
        }
    };
}

pub const NodeMeta = struct {
    cpu_free: u32,
    mem_free: u64,
    disk_free: u64,
    platform: u32,
    last_seen_ms: u64,
    version: u64, // HLC
};

pub const ServiceSpec = struct {
    service_id: u64,
    spec_hash: [32]u8,
    replicas: u16,
    platform_mask: u32,
    version: u64, // HLC
};

pub const ServicePlacement = struct {
    service_id: u64,
    replica_id: u16,
    node_id: u32,
    lease_epoch: u64,
    expires_at_ms: u64,
    score: i64,
    basis_meta_version: u64,
    version: u64, // HLC
};

pub const ServiceRuntime = struct {
    state: u8, // stopped/running/failed
    last_change_ms: u64,
};
```

`src/db/wal.zig`

```zig
const std = @import("std");
const types = @import("wal_types.zig");

pub const Wal = struct {
    buf: []u8,
    cursor: usize = 0,

    pub fn init(buf: []u8) Wal { return .{ .buf = buf }; }

    pub fn append(self: *Wal, kind: types.Kind, payload: []const u8) !void {
        const hdr = types.EntryHeader.init(kind, payload);
        if (self.cursor + hdr.totalLen() > self.buf.len) return error.DiskFull;
        hdr.write(self.buf[self.cursor..]);
        self.cursor += hdr.totalLen();
    }

    pub fn replay(self: *Wal, apply: *const fn (types.Kind, []const u8) void) void {
        var pos: usize = 0;
        while (pos + @sizeOf(types.EntryHeader) <= self.buf.len) {
            const entry = types.EntryHeader.read(self.buf[pos..]) orelse break;
            apply(entry.kind, entry.payload);
            pos += entry.totalLen();
        }
        self.cursor = pos;
    }
};
```

## Test Plan

Unit tests:
- `tests/hlc.zig`: ordering, packing/unpacking.
- `tests/crdt_merge.zig`: LWW + register tie-break rules.
- `tests/wal_v2.zig`: append/replay, CRC corruption handling.
- `tests/placement.zig`: deterministic scoring, tie-breaks, lease expiry.

Integration tests:
- `tests/gossip_roundtrip.zig`: encode/decode deltas, converge under replays.
- `tests/rebalance.zig`: replicas move when node meta changes; no oscillation.

Simulation tests:
- `tests/simulation.zig`: loss/partition/crash cases; convergence SLA.
- `tests/restart_replay.zig`: restart nodes, verify WAL replay restores specs and placements.

## Done Criteria

You are done when:
- WAL replay restores service specs and placements after restart.
- Placement converges across nodes with replicas and rebalancing.
- Systemd runtime matches placement decisions.
- Simulation tests pass under loss and partitions.
