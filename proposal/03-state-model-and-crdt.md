# Proposal (Page 3/5): State Model (ECS Tables) + CRDT Semantics

This page is a deep dive into the “ECS storage + functional core” state model: how we represent nodes, services, replicas, placements, and runtime state in memory, and how CRDT semantics keep replicas convergent.

The core thesis is that we do **not** need a complicated archetype ECS engine. We need:

- fixed‑capacity tables (SoA where it matters),
- explicit keys and indices,
- explicit dirty tracking,
- and explicit merge/version rules.

That gives us the performance profile of ECS and the clarity/testability profile of a functional core.

## 1) IDs, keys, and “entities”

The system has three stable identifiers:

- `NodeId` – stable identity of a node (u16 or u32). Deterministic in simulation.
- `ServiceId` – stable identity of a service spec (u64).
- `ReplicaId` – stable index within a service spec (`0..replicas-1`, u16).

A placement record is keyed by `(ServiceId, ReplicaId)`, which we call a `ReplicaKey`.

### Why explicit IDs (instead of generic entity IDs)

A classic ECS uses an opaque entity integer and attaches components by entity. That is useful when entities are created/destroyed frequently. In Myco’s domain, the “entities” already have stable IDs coming from the problem:

- service IDs are chosen externally,
- nodes are long‑lived,
- replicas are enumerable.

So the storage model is “ECS‑style” in layout, but **domain‑keyed**. This reduces indirection and makes diagrams and debugging output more meaningful (you will see `service_id=1000 replica=2`, not `entity=7421`).

## 2) Component tables (data layout)

We store each major domain component in a fixed table. Each table has:

- `slots[N]` containing `{active, id, version, payload...}`
- bounded “dirty” buffers to export deltas efficiently
- optional indices for faster lookup (e.g., hash -> spec blob)

A “slot” is a fixed record with an `active` flag. This mirrors the existing repository style: linear scans over bounded arrays are predictable and fast at the current scale.

### Big picture memory layout (ASCII)

```text
+--------------------------------------------------------------------------------+
| ECS World (domain-keyed tables; bounded, no-alloc hot paths)                    |
|                                                                                |
|  Nodes:                                                                        |
|   +----------------------+   +----------------------+   +--------------------+ |
|   | NodeMetaTable        |   | NodeIdentityTable    |   | NodeStatusTable    | |
|   | (CRDT LWW)           |   | (local + replicated) |   | (TTL/health)       | |
|   +----------+-----------+   +----------+-----------+   +----------+---------+ |
|              |                          |                          |           |
|              v                          v                          v           |
|  Services:                                                                     |
|   +----------------------+   +----------------------+   +--------------------+ |
|   | ServiceSpecTable     |   | ServiceSpecBlobStore |   | ServiceRuntime     | |
|   | (CRDT LWW summary)   |   | (by hash; optional)  |   | (local only)       | |
|   +----------+-----------+   +----------+-----------+   +----------+---------+ |
|              |                          |                          |           |
|              v                          v                          v           |
|  Placement:                                                                    |
|   +----------------------+   +----------------------+                            |
|   | PlacementTable       |   | ReplicaIndexTable    |                            |
|   | (CRDT register)      |   | (svc->replica slots) |                            |
|   +----------+-----------+   +----------+-----------+                            |
|              |                          |                                       |
|              v                          v                                       |
|  Dirty tracking:                                                                 |
|   +----------------------+   +----------------------+   +--------------------+ |
|   | dirty_node_meta      |   | dirty_service_specs  |   | dirty_placements   | |
|   +----------------------+   +----------------------+   +--------------------+ |
+--------------------------------------------------------------------------------+
```

### Table design guidelines

- **Stable iteration order** improves compression. If we iterate slots in a stable order (e.g., insertion order or sorted by ID), varint and delta coding compresses better.
- **Dirty buffers** should store compact “pointers” (slot indices or IDs + versions) rather than full payloads.
- **Separate replicated vs local state**. For example, `ServiceRuntime` is local and should not pollute gossip.

## 3) Component definitions (what we store)

This section describes each major component and why it exists.

### 3.1 NodeMeta (replicated)

Fields (example):
- `cpu_free`, `mem_free`, `disk_free`
- `platform` (bitmask or enum)
- `labels` (optional: compressed label set)
- `last_seen_ms` (TTL signal)
- `version` (HLC)

Semantics:
- Replicated as an LWW register keyed by `NodeId`.
- The primary use is placement eligibility and scoring.

Important constraint:
- NodeMeta is high churn; persisting every update to WAL can bloat storage. A practical choice is:
  - replicate NodeMeta via gossip,
  - keep it in memory,
  - optionally snapshot occasionally,
  - but **only WAL‑persist NodeMeta** if you truly require durable capacity planning across restarts.

### 3.2 ServiceSpec (replicated summary)

We split service spec into two layers:

1) **Spec summary** (replicated, small)
- `service_id`
- `spec_hash` (e.g., sha256 of the full spec)
- `replicas`
- `platform_mask`
- `constraints_hash` (optional)
- `version` (HLC)

2) **Spec blob** (local storage, fetched on demand)
- full env vars, args, systemd config details, resource requests

Why split?
- Gossip packets are 1024 bytes, and specs can grow quickly.
- Placement can run on summary fields (replicas, platform, resource requests) while fetching the blob only when a node needs to execute.

Semantics:
- Spec summary is LWW by HLC.
- Spec blob is content‑addressed by hash; it is validated on load.

### 3.3 ServiceRuntime (local)

Fields (example):
- `running: bool`
- `unit_name`
- `last_start_ms`, `last_exit_code`
- `backoff_state`

Semantics:
- Not replicated.
- Updated by reconcile.

Rationale:
- Runtime is an observation of the local machine. Replicating it as “truth” tends to create confusing feedback loops.

### 3.4 ServicePlacement (replicated)

Keyed by `ReplicaKey = (ServiceId, ReplicaId)`.

Fields (example):
- `node_id` (current owner)
- `lease_epoch` (monotonic counter)
- `expires_at_ms` (lease TTL)
- `score` (winner score used for decision)
- `basis_meta_version` (node meta version used when scoring)
- `version` (HLC)

Semantics:
- This is *not* a simple LWW. We use a deterministic register merge:
  1) higher `lease_epoch` wins
  2) newer HLC wins
  3) higher score wins
  4) lower node_id wins (stable tie-break)

Why this structure:
- It allows decentralized claiming while reducing oscillations.
- It makes “who owns the replica” a single convergent value.

## 4) CRDT merge rules (detail)

CRDT correctness here is mostly about being explicit about:

- how versions are compared,
- how deletes/tombstones are represented,
- and how to prevent split‑brain side effects.

### 4.1 HLC ordering

HLC provides total ordering for versions:

- compare `wall` first
- if equal, compare `logical`

Rules:
- local writes mint `nextNow()`.
- on receiving remote versions, we `observeNow(remote)`.

### 4.2 LWW register merge (NodeMeta, ServiceSpec)

For LWW:

- if `incoming.version` is newer than `current.version`, apply.
- otherwise ignore.

Edge cases:
- If versions tie exactly, use a deterministic tie-break (e.g., lower node_id or smaller hash). This avoids “equal version but different payload” ambiguity.

### 4.3 Placement register merge

Placement requires extra rules because we want leases:

- Treat `lease_epoch` as the primary clock for ownership changes.
- HLC is still used to ensure monotonicity and provide ordering when epochs tie.

A key insight: the merge rule is deterministic, but the *claim policy* can be conservative (hysteresis) to avoid churn.

### 4.4 Deletes and tombstones

Services and placements must support deletion:

- ServiceSpec deletion can be represented as a tombstone summary with a version.
- Placement deletion for a replica can be represented as a “null placement” record (node_id=0) with a version, or a dedicated `ReleasePlacement` entry.

In all cases:
- deletes must carry versions;
- deletes must be gossiped;
- tombstones should be GC’d after an epoch/retention window.

## 5) Dirty tracking and delta extraction

To gossip efficiently, we avoid scanning full tables on every tick.

We maintain bounded dirty lists per replicated component:

- `dirty_node_meta`: NodeIds updated since last export
- `dirty_service_specs`: ServiceIds updated since last export
- `dirty_placements`: ReplicaKeys updated since last export

When we apply an event or merge a remote delta, we mark the corresponding record dirty.

### Dirty marking flow (diagram)

```text
Event/Delta
  |
  v
merge/apply -> table record updated
  |
  v
push key into dirty buffer (drop-oldest on overflow)
  |
  v
Gossip encoder drains dirty buffers into packet sections
```

Key implementation note:
- Use a “missing set” style de-dup set (like the current code) to avoid pushing the same key repeatedly.

## 6) Functional reducers on top of ECS tables

Although we call the storage “ECS,” the logic style is closer to a functional core:

- reducers receive an event and a mutable world
- they update tables deterministically
- they emit effects into bounded buffers

This gives you the primary benefit of a reducer architecture: **tests can apply a sequence of events and assert the resulting world state** without involving network or systemd.

### Reducer layering (ASCII)

```text
+---------------------+
| Event               |
+----------+----------+
           |
           v
+---------------------+    +---------------------+    +---------------------+
| validate + normalize| -> | apply to tables     | -> | emit Effects        |
| (no I/O)            |    | (deterministic)     |    | (no I/O)            |
+---------------------+    +---------------------+    +---------------------+
```

## 7) What “scalability” means here

This design scales in two distinct ways:

1) **Runtime scalability** within fixed limits
- operations are O(N) over bounded arrays,
- no unbounded allocations,
- stable packet size.

2) **Engineering scalability**
- new fields become new component columns or new tables,
- merge rules are localized,
- encoding rules are localized.

ECS‑style storage helps with both, but the functional reducer discipline prevents the code from turning into an opaque framework.

Page 4 describes the WAL schema and the gossip encoding, including how we turn dirty tables into compact, compressible packet payloads.
