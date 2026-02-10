# Proposal (Page 1/5): Best-of-Both Architecture (ECS Storage + Functional Core + CRDT + WAL)

## Abstract

This proposal describes a “best of both worlds” implementation for Myco: we keep the **data‑oriented, cache‑friendly storage** and modular growth properties of an **ECS‑style world**, while adopting the **deterministic, testable, and replayable** development experience of a **functional core with event sourcing**. Concretely:

- **ECS provides storage**: nodes, services, and replicas are stored in fixed‑capacity, columnar component tables.
- **Functional core provides semantics**: all changes happen via typed events applied by reducers/systems that do **no I/O**.
- **CRDTs provide convergence**: replicated components use HLC‑based last‑write‑wins (LWW) registers or deterministic registers for placement.
- **WAL provides durability**: local intent (service specs, placements, policy changes) is appended to a versioned write‑ahead log and replayed on boot.

The outcome is an architecture that keeps Myco’s original constraints intact: fixed packet size, low allocations, deterministic identity, and simulation‑friendly behavior—while enabling durable service placement with replicas and rebalancing.

## Background: What we have today (why we’re changing)

The current repo already shows strong data‑oriented instincts:

- A node is a single “owner” struct (`src/node.zig`) with fixed buffers and a version store.
- Gossip is packed into a strict **1024‑byte packet** and uses compact digests (`src/node/codec.zig`).
- Conflict resolution is last‑write‑wins based on Hybrid Logical Clocks (`src/sync/hlc.zig`).
- There is a minimal WAL (`src/db/wal.zig`), but it currently models durability for a narrow slice of state.

The problem is not that these choices are wrong; the problem is that **the scope is expanding**:

- Each node now needs a converged view of **node capabilities** (cpu/mem/disk/platform/health).
- The cluster needs a converged view of **service metadata** (env vars, args, platform constraints).
- Services can have **replicas**, and placements should **rebalance** freely when conditions change.
- Placement decisions must be **durable** (survive restart) and **convergent** (avoid long‑lived splits).

A monolithic node struct can be stretched to support this, but it becomes increasingly difficult to:

- keep state durable and replayable,
- keep gossip deltas compact,
- keep placement logic explicit and testable,
- and keep changes readable as the feature surface grows.

## Design goals

1) **Durability for intent**
- Service specs and placement claims must survive restarts.
- Recovery must be deterministic and verifiable.

2) **Eventual convergence**
- Under loss/partition, the cluster converges to the same specs and placements.
- Conflicts have deterministic tie‑breaks.

3) **Low allocation, fixed bounds**
- Hot paths avoid heap allocations.
- Memory usage is explicit via limits and bounded arrays.

4) **Packet‑friendly deltas**
- Gossip stays within 1024 bytes.
- Deltas are compressible and minimize entropy.

5) **Maintainable evolution**
- Adding a new replicated field should be “add component + reducer + encoding,” not “thread a new field through a god object.”
- Placement policy should be testable in isolation.

## Non‑goals (important)

- We are not aiming for a general‑purpose ECS framework. This is *ECS‑style storage*, not a full game‑engine archetype system.
- We are not aiming for linearizable “one true” state. This remains an eventually consistent system with CRDT semantics, except where we explicitly introduce lease/epoch rules.
- We are not making systemd orchestration perfect on day one. We focus on an idempotent reconcile loop and safe failure handling.

## Constraints carried forward from the original project

- **Packet size fixed at 1024 bytes**. We will not “just send more state.”
- **HLC semantics** remain the ordering primitive; wall clocks are not compared directly.
- **Bounded memory**: use fixed tables and bounded buffers (similar to current `limits`).
- **Simulation‑friendly determinism**: deterministic identity and deterministic tie‑breaks.
- **Minimal footprint**: avoid heavy embedded DB dependencies.

## The best‑of‑both pattern

The core idea is to explicitly separate three things:

1) **Storage (ECS world)**
- The “world” is a set of fixed‑capacity, columnar tables for components.
- Entities are just IDs: `NodeId`, `ServiceId`, `ReplicaKey`.

2) **Semantics (functional core reducers/systems)**
- Reducers take `(world, input) -> (world', effects)`.
- Reducers never perform I/O; they only return a list of effects.

3) **I/O (imperative shell)**
- A runtime loop gathers inputs (timers, packets, API commands).
- It translates inputs into typed events.
- It appends durable events to WAL, applies them to the world, then executes effects.

This makes the system both modular (ECS systems) and deterministic (functional core + replay).

## Overall app architecture (ASCII)

```text
+-----------------------------------------------------------------------------------+
|                                     Myco Daemon                                   |
|                                                                                   |
|  +-----------------+   +---------------------+   +------------------------------+ |
|  | Inputs           |   | Functional Core     |   | Imperative Shell             | |
|  | - timers         |-->| (reducers/systems)  |-->| (I/O + scheduling)           | |
|  | - packets        |   |                     |   |                              | |
|  | - API/CLI cmds   |   |  +---------------+  |   |  +------------------------+  | |
|  +-----------------+   |  | ECS World      |  |   |  | WAL (durable log)      |  | |
|                        |  | (SoA tables)   |  |   |  | append + fsync         |  | |
|                        |  +-------+-------+  |   |  +-----------+------------+  | |
|                        |          |          |   |              |               | |
|                        |          v          |   |              v               | |
|                        |  +---------------+  |   |  +------------------------+  | |
|                        |  | Effects       |  |   |  | Side effects           |  | |
|                        |  | - send gossip |  |   |  | - send packets         |  | |
|                        |  | - systemd ops |  |   |  | - systemd reconcile    |  | |
|                        |  | - metrics     |  |   |  | - write snapshots      |  | |
|                        |  +---------------+  |   |  +------------------------+  | |
|  +-----------------+   +---------------------+   +------------------------------+ |
|  | Outputs          |                                                              |
|  | - gossip packets |                                                              |
|  | - systemd units  |                                                              |
|  | - API responses  |                                                              |
|  +-----------------+                                                              |
+-----------------------------------------------------------------------------------+
```

## Main runtime flow (flow diagram)

```text
(boot)
  |
  | 1) load identity/config
  | 2) replay WAL -> ECS world
  v
(loop tick)
  |
  | gather inputs: [timer tick] + [inbound packets] + [API commands]
  v
  decode -> normalize -> typed Events
  |
  | durable events: WAL.append + fsync (before external side effects)
  v
  apply reducers/systems (CRDT merge, placement, reconcile decisions)
  |
  v
  execute Effects (send gossip, write files, call systemd)
  |
  v
  repeat
```

## Why this is a good fit (performance, readability, scalability)

### Performance
- ECS storage is inherently **columnar**, which makes scans over “just the fields you need” cheaper.
- The functional core style discourages hidden allocations and encourages explicit buffers.
- Encoding deltas from component tables makes digests more compressible (stable ordering, columnar deltas).

### Readability
- You can read each reducer/system as a local story: “given these inputs and current world state, produce changes and effects.”
- Event types define the vocabulary of the system and become natural log/debug tools.
- The I/O shell is isolated: network and systemd behavior cannot leak into state logic.

### Scalability (software and runtime)
- As you add new metadata fields, you add a component and update its merge/encoding rules.
- Placement policy can grow (anti‑affinity, zones, priorities) without rewriting the entire node.
- Runtime costs remain predictable because tables are bounded and loops are explicit.

## Preview of the internal “services” (subsystems)

The rest of this proposal will treat major subsystems as “services” with clear interfaces:

- **WAL service**: typed append, CRC, replay, compaction.
- **State engine service**: ECS world + reducers + effect builder.
- **CRDT merge service**: LWW registers, placement register, merge helpers.
- **Gossip service**: per‑component delta encoding within 1024‑byte packets.
- **Placement service**: replica‑aware scoring, claiming, leases, hysteresis.
- **Reconcile service**: idempotent systemd converge to desired state.
- **API/CLI service**: converts user actions into events.

Page 2 describes each service’s interface and provides detailed ASCII diagrams for each.
