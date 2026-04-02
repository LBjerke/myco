# Proposal (Page 2/5): Services, Interfaces, and Execution Model

This page defines the internal “services” (subsystems) of the best‑of‑both architecture. The goal is to make the codebase navigable: each subsystem has a clear interface, an ASCII architecture diagram, and a flow diagram that explains how data moves through it.

> Terminology: the word “service” below means an internal subsystem (module) of the daemon, not a user workload. User workloads are represented as `ServiceSpec` and `ServiceReplica` entities in state.

## Execution model: one event loop, explicit phases

We run a single deterministic loop:

1) ingest inputs (network packets, timers, API commands)
2) normalize to typed events
3) append durable events to WAL (before external side effects)
4) apply reducers/systems (mutate ECS tables, generate effects)
5) execute effects (network sends, systemd operations)

This preserves the original project’s feel (explicit `tick`) while gaining modularity.

## Service A: Ingress (CLI/API Command Service)

Purpose:
- Accepts human or API requests (“deploy this,” “scale replicas,” “drain node,” “set labels”).
- Validates input and emits typed domain events.
- Does not directly change in-memory state; it creates events that go through the same pipeline as gossip.

ASCII architecture:

```text
+---------------------+         +-----------------------------+
| CLI / API handlers  |  cmds   | Ingress Service             |
| - parse JSON        |-------> | - validate + normalize       |
| - authz (optional)  |         | - build typed Events         |
+---------------------+         +--------------+--------------+
                                               |
                                               v
                                     +-------------------+
                                     | Event queue        |
                                     | (bounded)          |
                                     +-------------------+
```

Flow diagram:

```text
request -> parse -> validate -> normalize -> Event(kind, id, payload, hlc)
   |                                             |
   |                                             v
   +------------------------------------- enqueue for tick
```

Key interfaces (sketch):
- `fn handleDeploy(req) -> []Event`
- `fn handleScale(service_id, replicas) -> []Event`
- `fn handleDrain(node_id) -> []Event`

Notes:
- Every ingress mutation must choose whether it is durable (WAL) or ephemeral.
- Durable changes include service specs, replica counts, placement overrides.

## Service B: WAL (Durability Service)

Purpose:
- Provide durable, append-only recording of intent and decisions.
- Allow deterministic replay to reconstruct state.
- Detect corruption using CRC and versioned headers.

ASCII architecture:

```text
+---------------------+       +--------------------------+       +------------------+
| Domain Events        |       | WAL Service              |       | Storage medium   |
| (durable subset)     |-----> | - encode header+payload  |-----> | file/segment     |
+---------------------+       | - crc + fsync            |       | (bounded)        |
                              | - replay iterator        |       +------------------+
                              | - compaction snapshot    |
                              +------------+-------------+
                                           |
                                           v
                                   +---------------+
                                   | Replay output |
                                   | (Events)      |
                                   +---------------+
```

Flow diagram:

```text
(append)
  Event -> encode -> write -> fsync -> ack

(replay)
  segment -> scan -> verify crc -> decode -> yield Event
```

Key interfaces (sketch):
- `fn append(event: Event) !void`
- `fn replay(apply: fn(Event) void) void`
- `fn compact(snapshot: []u8) !void`

Notes:
- “Durable before side effects” is a safety rule: if placement will start a systemd unit, the placement claim must already be in WAL.

## Service C: State Engine (ECS Storage + Reducer Orchestrator)

Purpose:
- Own the ECS world: fixed-capacity component tables.
- Apply reducers/systems in deterministic order.
- Collect effects into bounded buffers.

ASCII architecture:

```text
+----------------------+        +----------------------------+
| ECS World            |        | Reducer Orchestrator       |
| - NodeMetaTable      |<------>| - apply(Event)             |
| - ServiceSpecTable   |        | - run systems in order     |
| - PlacementTable     |        | - build Effects            |
| - RuntimeTable (local)|       +-------------+--------------+
+----------+-----------+                      |
           |                                  v
           v                        +----------------------+
+----------------------+            | Effects buffer        |
| Indices/Dirty sets   |            | - SendPacket          |
| - dirty_specs        |            | - SystemdStart/Stop   |
| - dirty_placements   |            | - Metrics             |
+----------------------+            +----------------------+
```

Flow diagram:

```text
Event
  |
  v
apply reducers (validate + mutate tables)
  |
  v
mark dirty + emit effects
  |
  v
return Effects to shell
```

Key interfaces (sketch):
- `fn applyEvent(world: *World, event: Event, effects: *Effects) void`
- `fn tick(world: *World, inputs: Inputs) Effects`

Notes:
- This is where ECS and functional core meet: reducers may mutate tables (imperative), but they must be deterministic and I/O-free.

## Service D: CRDT Merge (Convergence Service)

Purpose:
- Provide merge semantics for replicated components.
- Use HLC versions for LWW registers.
- Provide deterministic tie-break rules for placement.

ASCII architecture:

```text
+----------------------+        +----------------------------+
| Incoming deltas      |        | CRDT Merge Service         |
| (from gossip)        |------->| - LWW merge (hlc newer)    |
+----------------------+        | - placement register merge |
                                 | - tombstone/ttl handling  |
                                 +-------------+--------------+
                                               |
                                               v
                                     +----------------------+
                                     | ECS tables updated   |
                                     | + dirty flags        |
                                     +----------------------+
```

Flow diagram:

```text
(delta)
  (id, version, payload)
        |
        v
  compare versions (HLC)
   | newer? yes -> apply
   | newer? no  -> ignore
        |
        v
  mark dirty for gossip/reconcile
```

Key interfaces (sketch):
- `fn mergeLww(current: T, incoming: T) T`
- `fn mergePlacement(cur: Placement, inc: Placement) Placement`

Notes:
- NodeMeta often uses a TTL (`last_seen`) to avoid treating dead nodes as candidates.

## Service E: Gossip (Networking + Codec Service)

Purpose:
- Encode component deltas into 1024-byte packets.
- Decode packets into per-component delta streams.
- Maintain per-peer watermarks to reduce redundant sends.

ASCII architecture:

```text
+-----------------------+    +------------------------+    +-------------------+
| Dirty sets / deltas   |    | Gossip Codec Service   |    | Network Transport |
| - specs, placements   |--->| - per-component sections|--->| send/recv packets |
| - node meta summaries |    | - varint + delta coding |    +-------------------+
+-----------------------+    | - optional compression  |
                             +-----------+------------+
                                         |
                                         v
                               +---------------------+
                               | Decode -> deltas    |
                               +---------------------+
```

Flow diagram:

```text
encode:
  gather dirty -> sort/stable order -> pack sections -> compress if useful -> emit Packet

decode:
  Packet -> decompress -> parse sections -> yield deltas -> CRDT merge
```

Key interfaces (sketch):
- `fn encode(world, peer_state, out_packet_buf) Packet`
- `fn decode(packet, out_deltas_buf) []Delta`

Notes:
- ECS helps compressibility because deltas come from columnar tables and stable iteration order.

## Service F: Placement (Scheduling + Claim Service)

Purpose:
- Decide which nodes should run which replicas.
- Claim placements when the local node is the best candidate.
- Use leases + hysteresis to avoid oscillation.

ASCII architecture:

```text
+----------------------+     +--------------------------+     +---------------------+
| Inputs               |     | Placement Service        |     | Outputs             |
| - NodeMeta (CRDT)    |---->| - eligibility filter     |---->| - SetPlacement Event|
| - ServiceSpec (CRDT) |     | - deterministic scoring  |     | - Reconcile intent  |
| - Current placements |     | - lease renew/steal      |     +---------------------+
+----------------------+     +-------------+------------+
                                           |
                                           v
                                  +------------------+
                                  | Effects          |
                                  | - WAL append     |
                                  | - gossip delta   |
                                  +------------------+
```

Flow diagram:

```text
for each ServiceReplica:
  candidates <- eligible nodes
  winner <- argmax(score)
  if winner == self and (missing/expired/override):
      emit SetPlacement
      (durable via WAL)
```

Key interfaces (sketch):
- `fn computeScore(node_meta, service_spec) i64`
- `fn proposePlacements(world, now_ms) []Event`

Notes:
- Replicas introduce anti-affinity (try to spread) and capacity constraints.

## Service G: Reconcile (Systemd Convergence Service)

Purpose:
- Ensure local runtime matches desired placements.
- Be idempotent: repeated reconcile should be safe.
- Prefer “desired state” over “deploy hooks.”

ASCII architecture:

```text
+-------------------------+      +-------------------------+
| Desired state           |      | Reconcile Service       |
| - placements where me   |----->| - diff desired vs actual|
| - service spec hash     |      | - start/stop/restart    |
+-------------------------+      | - backoff + health gate |
                                +-----------+-------------+
                                            |
                                            v
                                   +------------------+
                                   | systemd runtime  |
                                   | unit files + ctl |
                                   +------------------+
```

Flow diagram:

```text
desired <- placements for self
actual  <- runtime table (cached) + systemd query (optional)
plan    <- diff(desired, actual)
execute <- start/stop/restart with backoff
update runtime component
```

Key interfaces (sketch):
- `fn computePlan(world) []SystemdAction`
- `fn applyPlan(actions) !void`

Notes:
- Reconcile is the main guard against split-brain side effects: even if gossip temporarily disagrees, leases and reconcile gates reduce churn.

## Service H (Optional): Spec Blob Store / Fetch

Purpose:
- Keep gossip packets small by sending spec hashes and versions.
- Store full spec bodies locally and fetch on demand.

ASCII architecture:

```text
+--------------------+      +---------------------+      +---------------------+
| ServiceSpec (hash) |      | Spec Store          |      | Fetch (optional)    |
| in CRDT component  |----->| - local blobs by hash|<---->| - peer request/reply|
+--------------------+      | - GC/retention       |      +---------------------+
                            +---------------------+
```

Flow diagram:

```text
need full spec?
  if local has hash -> load
  else -> request hash from peer -> verify -> store -> load
```

Notes:
- This is optional. You can start by embedding specs in WAL and gossip only summaries.

## Summary: How the services compose

At runtime, the services form a clean pipeline:

- Ingress and Gossip both create Events.
- WAL persists durable Events.
- State Engine applies Events and runs systems.
- CRDT Merge updates replicated components.
- Placement emits new placement Events.
- Gossip sends deltas.
- Reconcile executes systemd actions.

The next pages dive into the data model (ECS tables + CRDT semantics), WAL schema, gossip encoding, and placement details.
