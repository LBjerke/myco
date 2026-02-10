# Migration Guide: Monolithic Node -> ECS-CRDT + WAL

This guide is written like IKEA instructions: short stories, numbered steps, and checkpoints. It assumes you are migrating the current Myco codebase into the ECS-CRDT + WAL architecture described in `Report.md`.

## Story 0: The Map and the Boxes

Imagine you are moving into a new apartment. You do not throw away your old furniture on day one. You carry the old furniture into the new rooms, then slowly replace pieces. The goal is to keep the house livable at every step.

In this migration:
- The **old furniture** is the monolithic `Node` in `src/node.zig`.
- The **new rooms** are ECS components and systems.
- The **moving truck** is the WAL, which must still deliver your state reliably.

We move in phases, and we never leave the system in a half-built state.

## Safety Rules (Read First)

1) Always keep `tests/simulation.zig` passing after each phase.
2) Do not delete old logic until the new logic is proven.
3) Use feature flags to guard new behaviors.
4) Keep WAL backward-compatible until the final cutover.

## Phase 1: Build the Frame (ECS Scaffolding)

Goal: Add ECS structure without changing behavior.

### Step 1: Create the ECS world

Action:
- Add `src/ecs/world.zig` with a simple entity allocator and component storage.
- Add `src/ecs/components.zig` with placeholders for Node fields.

Checkpoint:
- Build still passes.
- No runtime behavior change.

### Step 2: Wrap Node with a facade

Action:
- Create `src/node/facade.zig` or update `src/node.zig` to hold `(world, node_entity)`.
- Inside `Node.init`, populate components from the old fields.
- Keep `Node.tick` and `Node.injectService` signatures unchanged.

Checkpoint:
- `tests/simulation.zig` passes.
- Node behavior is unchanged.

## Phase 2: Split State into Components

Goal: CRDT data and node metadata move into ECS components.

### Step 3: Componentize the service version store

Action:
- Add `ServiceSpec` and `ServiceVersion` components.
- Map the existing `ServiceStore` data into these components.
- Update gossip encode/decode to read from component tables.

Checkpoint:
- Gossip still converges in simulations.
- `tests/sync_crdt.zig` passes.

### Step 4: Add NodeMeta components

Action:
- Add a `NodeMeta` component with cpu/mem/disk/platform/last_seen.
- Add a small system to update `NodeMeta` periodically.

Checkpoint:
- Node metadata appears in gossip (even if only local for now).

## Phase 3: WAL v2 (Typed Entries)

Goal: WAL stores service specs and placements, not just the knowledge counter.

### Step 5: Define WAL v2 entry types

Action:
- Add a versioned entry header (version + kind + length + crc).
- Add entry kinds: `PutServiceSpec`, `SetPlacement`, `UpdateNodeMeta`.

Checkpoint:
- WAL can still read old v1 entries.

### Step 6: Implement replay into ECS

Action:
- Add `ecs/systems/replay.zig` to apply WAL entries.
- On boot, replay WAL to populate components.

Checkpoint:
- Restarting a node preserves service state.

### Step 7: Add compaction/snapshot

Action:
- Add a compact step: write a snapshot and truncate WAL.
- Gate compaction with config so it can be turned off.

Checkpoint:
- Startup time remains stable with large logs.

## Phase 4: Placement and Rebalancing

Goal: Deterministic, replica-aware placement with leases and rebalancing.

### Step 8: Placement scoring system

Action:
- Add `ecs/systems/placement.zig`.
- Implement deterministic scoring (resource weighted + tie-break by node_id).
- Filter by platform and resource constraints.

Checkpoint:
- All nodes compute the same winner for each replica.

### Step 9: Claims and leases

Action:
- Add `ServicePlacement` component with `replica_id`, `lease_epoch`, `expires_at`.
- If self wins, append a `SetPlacement` WAL entry and update CRDT state.

Checkpoint:
- Nodes converge on the same placement under stable conditions.

### Step 10: Rebalance policy

Action:
- Add hysteresis (minimum score improvement) to avoid thrashing.
- Allow free movement if a better node appears.

Checkpoint:
- Replica movements are stable, not oscillating.

## Phase 5: Systemd Reconciliation

Goal: Local runtime matches placement decisions.

### Step 11: Reconcile loop

Action:
- Add `ecs/systems/reconcile.zig` to start/stop systemd units based on placement.
- Use existing `src/systemd.zig` helpers for unit generation.

Checkpoint:
- Services run only on nodes that currently own placements.

### Step 12: Remove legacy paths

Action:
- Deprecate `on_deploy` callbacks after reconcile is stable.
- Remove unused fields from the old `Node` struct.

Checkpoint:
- All service activation flows through ECS.

## Phase 6: Cleanup and Hardening

Goal: Remove migration scaffolding and stabilize.

### Step 13: Remove feature flags

Action:
- Remove flags once the ECS+WAL path is the only path.
- Delete dead code and old CRDT store pathways.

Checkpoint:
- Codebase is simpler than before migration.

### Step 14: Add regression tests

Action:
- Add tests for WAL v2 replay, mixed v1/v2 logs, placement convergence, and rebalancing.
- Keep simulation tests running in CI.

Checkpoint:
- New tests pass in CI; no regressions.

## Troubleshooting Guide

- If startup is slow: check WAL size and compaction frequency.
- If placements oscillate: increase hysteresis threshold or lease duration.
- If nodes disagree on placement: verify CRDT merge order and tie-break rules.
- If services fail to start: verify systemd unit generation and reconcile logic.

## Done Criteria

You are done when:
- All services survive restarts (durable via WAL v2).
- Placement converges across nodes with replicas and rebalancing.
- Systemd state matches placement state.
- Simulation tests pass with ECS enabled.
