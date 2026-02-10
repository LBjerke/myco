# Report: Persistence Design Options for Myco

This report ranks five persistence designs for Myco's cluster state (nodes, services, placements, metadata). It expands each option with detailed descriptions, pros and cons relative to the other designs, and architecture diagrams. It also includes ECS-CRDT architectures for each persistence alternative.

## Current vs Proposed Architecture

Current architecture (today):

```text
          +---------------------------+
          |   Node (monolithic)       |
          |   - Identity              |
          |   - HLC                   |
          |   - ServiceStore (CRDT)   |
          |   - Service slots         |
          |   - WAL (knowledge only)  |
          |   - Missing/outbox        |
          +-------------+-------------+
                        |
                        v
                +---------------+
                | on_deploy hook|
                +------+--------+
                       |
                       v
               +-----------------+
               | systemd apply   |
               | (ServiceConfig) |
               +-----------------+
                        ^
                        |
    +-------------------+--------------------+
    | gossip digests / deltas (ServiceStore) |
    +----------------------------------------+
```

Notes:
- The node is a single struct that owns identity, CRDT store, gossip buffers, and a small WAL used only for a knowledge counter. Most state is in-memory.
- Service metadata and runtime configuration live outside the node in `ServiceConfig` files, and `on_deploy` triggers systemd updates.
- Gossip is primarily about service versions; full service specs are not durable in the WAL.

Proposed architecture (ECS-CRDT + WAL durability):

```text
      +------------------------------+
      | ECS World (entities+comps)   |
      | Node: Meta/Identity/Health   |
      | Service: Spec/Placement/Run  |
      +------+-----------------------+
             |
             v
  +---------------------+      +---------------------+
  | CRDT Merge System   |<---->| Gossip I/O          |
  | (node+service state)|      | (deltas/hashes)     |
  +----------+----------+      +---------------------+
             |
             v
  +---------------------+      +---------------------+
  | Placement/Lease Sys |----->| WAL Append          |
  | (replicas+rebalance)|      | (typed entries)     |
  +----------+----------+      +----------+----------+
             |                           |
             v                           v
     +---------------+           +------------------+
     | Systemd Recon |<----------| WAL Replay (boot)|
     +---------------+           +------------------+
```

Notes:
- State is decomposed into ECS components (node meta, service specs, placement, runtime), and CRDT semantics govern replicated fields.
- WAL becomes the durable source for service specs and placement claims; replay reconstructs the ECS world deterministically.
- Placement and reconciliation are explicit systems, allowing replica-aware decisions and safe rebalancing without hiding logic in a monolithic node.

## Ranking (for Myco constraints)

Assumptions: Zig codebase, fixed-capacity buffers, offline-friendly operation, and gossip-based replication. Node metrics are high churn and may not need durability; service specs and placements do. The ranking balances durability, operational simplicity, and predictable performance.

1) WAL + Replay (baseline, with periodic compaction)
- Best overall fit for append-heavy durability with low overhead and a clear ordering model.
- Strong default for offline-first operation and deterministic recovery.

2) Content-Addressed Store + Manifest
- Best when service specs are large or repeated and benefit from deduplication and rollbacks.
- Slightly more complex than WAL, but offers strong integrity and clear versioning.

3) Snapshot Store (atomic full snapshots)
- Best for rapid cold starts and simplicity, but trades off durability between snapshots.
- Works well if state changes are moderate and bounded.

4) Embedded Transactional DB (SQLite/LMDB)
- Strong durability and queries, but heavier runtime and less predictable memory behavior in Zig.
- Best when ad-hoc queries and constraints are core requirements.

5) External Replicated Store (etcd/consul/raft)
- Strongest coordination and conflict resolution, but highest operational burden.
- Best when centralized authority is required and offline operation is not a priority.

## Design 1: WAL + Replay

Diagram:

```text
+--------------------+     +------------------------+
| Local mutations    | --> | WAL append (typed log) |
+---------+----------+     +-----------+------------+
          |                          |
          |                          v
          |                 +--------------------+
          |                 | Replay + verify    |
          |                 | (CRC, versioning)  |
          |                 +----------+---------+
          |                            |
          v                            v
+--------------------+       +-----------------------+
| In-memory state    |<----->| Gossip sync / deltas  |
| (services, nodes)  |       +-----------------------+
+---------+----------+                 |
          |                            v
          v                    +---------------+
+--------------------+         | Systemd recon |
| Scheduler / policy |         +---------------+
+--------------------+
```

Description:
- A write-ahead log records every durable mutation as an append-only entry. The log is replayed on startup to rebuild the state of services, placements, and any durable node metadata. A versioned entry format plus checksums keep recovery deterministic and robust.
- WAL fits Myco's constraints because it is sequential I/O, which is fast and predictable even on constrained disks. The ordering semantics align with CRDT merge logic and HLC versions used in gossip.
- Compaction or periodic snapshots are optional but recommended for bounded replay times. This keeps startup time stable without losing the benefits of an append-only log.

Performance vs others:
- Write throughput: best or tied-best because it is pure append I/O and minimal CPU per entry.
- Read/startup: slower than snapshots and content-addressed manifests if the log is long, but faster than external stores on cold boot when compaction is used.
- CPU: linear replay cost; compaction amortizes this and keeps the steady-state cost low.

Readability/understandability vs others:
- Clear causal ordering improves reasoning about state transitions more than CRDT-only designs.
- More explicit data flow than DB-backed systems because state is rebuilt from a single sequence.
- Slightly more complex than snapshots due to replay and migration logic.

Pros (relative to all other designs):
- Deterministic recovery, explicit ordering, and strong durability with minimal runtime overhead.
- Natural fit for append-heavy workloads and low-level Zig implementations.
- Straightforward to test and simulate by replaying logs.

Cons (relative to all other designs):
- Replay time grows with log size unless compaction is implemented.
- Schema evolution requires careful versioning and migration code.
- Not as convenient as a DB for ad-hoc queries or complex filtering.

ECS-CRDT architecture using WAL:

```text
+------------------------+     +-----------------------+
| ECS World (entities)   |<--->| CRDT Merge System     |
| Node, Service, Placement|     +-----------------------+
+-----------+------------+                |
            |                             v
            |                      +-------------+
            |                      | Gossip I/O  |
            |                      +-------------+
            |
            v
+------------------------+     +------------------------+
| WAL Append (typed)     | --> | Replay on boot         |
| PutSpec / SetPlacement |     | rebuild ECS state      |
+------------------------+     +------------------------+
```

## Design 2: Snapshot Store (Atomic Full Snapshots)

Diagram:

```text
+--------------------+     +-----------------------+
| Local mutations    | --> | In-memory state       |
+---------+----------+     | (tables/components)   |
          |                +-----------+-----------+
          |                            |
          |                            v
          |                  +--------------------+
          |                  | Snapshot writer    |
          |                  | (atomic rename)    |
          |                  +----------+---------+
          |                             |
          v                             v
+--------------------+        +-----------------------+
| Load snapshot      | <----  | Snapshot files        |
+--------------------+        +-----------------------+
```

Description:
- Periodic snapshots serialize full state to a file (or a small set of files), then atomically replace the previous snapshot. On startup, the node loads the latest snapshot directly into memory.
- The snapshot strategy is conceptually simple: the snapshot is the truth. There is no replay step, so cold start time is consistent.
- In practice, snapshotting must ensure a consistent view across tables or components. For ECS-like layouts, this usually means a pause-the-world or copy-on-write strategy for the snapshot boundary.

Performance vs others:
- Write throughput: worse than WAL and CAS because the entire state is rewritten periodically.
- Read/startup: best or tied-best because boot is a single file load.
- CPU: highest cost during snapshot creation, minimal overhead otherwise.

Readability/understandability vs others:
- Easiest to explain and debug; the snapshot file is the state.
- Less conceptual overhead than WAL replay or DB transactions.
- Harder than WAL to explain durability gaps between snapshots.

Pros (relative to all other designs):
- Very simple recovery path and predictable cold boot times.
- Easy manual inspection and offline debugging.
- Minimal moving parts in the runtime state machine.

Cons (relative to all other designs):
- Can lose updates between snapshots unless the interval is very short.
- Large write amplification for large or high-churn state.
- Requires a safe point or copy-on-write to guarantee consistency.

ECS-CRDT architecture using snapshots:

```text
+------------------------+     +-----------------------+
| ECS World (entities)   |<--->| CRDT Merge System     |
| Node, Service, Placement|     +-----------------------+
+-----------+------------+                |
            |                             v
            |                      +-------------+
            |                      | Gossip I/O  |
            |                      +-------------+
            |
            v
+------------------------+     +------------------------+
| Snapshot writer        | --> | Snapshot files         |
| (atomic replace)       |     | (full state)           |
+------------------------+     +------------------------+
boot: snapshot -> ECS world
```

## Design 3: Embedded Transactional DB (SQLite/LMDB)

Diagram:

```text
+--------------------+     +------------------------+
| Local mutations    | --> | DB transaction commit  |
+---------+----------+     +-----------+------------+
          |                          |
          v                          v
+--------------------+     +------------------------+
| Query/load cache   | <-- | Persistent DB files    |
+---------+----------+     +------------------------+
          |
          v
+--------------------+
| In-memory caches   |
+--------------------+
```

Description:
- State is stored in an embedded transactional database. Mutations are committed through transactions and can be queried directly or cached into memory for fast access.
- The DB provides schema constraints and indexing, which can be attractive for complex queries (for example, filtering by platform or matching node capabilities).
- This option adds an external dependency and introduces a layer that must be tuned for performance, especially in a low-level Zig environment with fixed buffers.

Performance vs others:
- Write throughput: slower than WAL and often slower than CAS due to transactional overhead.
- Read/startup: good with indices but usually slower than snapshots; depends on cache strategy.
- CPU: higher overhead from query planning, locking, and transaction management.

Readability/understandability vs others:
- High-level schema and queries are readable, but data flow is less explicit than WAL.
- Easier to evolve with migrations than binary log formats.
- Adds conceptual complexity in a codebase otherwise designed around fixed-size buffers and deterministic memory.

Pros (relative to all other designs):
- Strong ACID durability and rich querying.
- Well-understood migration tooling and integrity checks.
- Simplifies complex filters and joins across service and node metadata.

Cons (relative to all other designs):
- Heavier runtime overhead and less predictable memory use.
- Integration complexity in Zig and additional dependency surface area.
- Debugging performance issues can be more subtle than with WAL or snapshots.

ECS-CRDT architecture using an embedded DB:

```text
+------------------------+     +-----------------------+
| ECS World (entities)   |<--->| CRDT Merge System     |
| Node, Service, Placement|     +-----------------------+
+-----------+------------+                |
            |                             v
            |                      +-------------+
            |                      | Gossip I/O  |
            |                      +-------------+
            |
            v
+------------------------+     +------------------------+
| DB writes/transactions | --> | DB files               |
| (tables or KV)         |     | (SQLite/LMDB)          |
+------------------------+     +------------------------+
boot: DB -> load caches -> ECS world
```

## Design 4: Content-Addressed Store + Manifest

Diagram:

```text
+--------------------+     +------------------------+
| Local mutations    | --> | Serialize to blob      |
+---------+----------+     +-----------+------------+
          |                          |
          |                          v
          |                 +---------------------+
          |                 | Blob store (by hash)|
          |                 +----------+----------+
          |                            |
          v                            v
+--------------------+     +------------------------+
| Update manifest    | --> | Manifest (id -> hash)  |
+---------+----------+     +------------------------+
          |
          v
+--------------------+
| Boot: load manifest|
+--------------------+
```

Description:
- State changes are written as immutable blobs, keyed by their content hash. A small manifest maps entity IDs (service IDs, node IDs) to blob hashes and is atomically updated.
- This model is attractive for large, infrequently changing service specs because blobs are deduplicated and can be rolled back simply by switching the manifest pointer.
- Garbage collection is necessary to remove unreferenced blobs and keep storage bounded.

Performance vs others:
- Write throughput: slower than WAL but often faster than full snapshots.
- Read/startup: good if the manifest is compact; slower than snapshots if many blobs must be read.
- CPU: moderate, with hashing cost traded for integrity and deduplication.

Readability/understandability vs others:
- More complex than WAL and snapshots because state is spread across blobs.
- Easier to reason about versioning and rollback than DB models.
- Indirection can make debugging slightly harder without tooling.

Pros (relative to all other designs):
- Strong integrity guarantees with content hashes.
- Deduplication reduces storage for repeated service specs.
- Clear rollback and versioning semantics through manifest updates.

Cons (relative to all other designs):
- Requires garbage collection and storage management.
- Extra indirection on reads and more moving parts than WAL.
- Operational complexity is higher than snapshots but lower than external stores.

ECS-CRDT architecture using CAS + manifest:

```text
+------------------------+     +-----------------------+
| ECS World (entities)   |<--->| CRDT Merge System     |
| Node, Service, Placement|     +-----------------------+
+-----------+------------+                |
            |                             v
            |                      +-------------+
            |                      | Gossip I/O  |
            |                      +-------------+
            |
            v
+------------------------+     +------------------------+
| Write blob + hash      | --> | Blob store             |
| Update manifest        |     | Manifest (id -> hash)  |
+------------------------+     +------------------------+
boot: manifest -> blobs -> ECS world
```

## Design 5: External Replicated Store (etcd/consul/raft)

Diagram:

```text
+--------------------+     +------------------------+
| Local mutations    | --> | Cluster KV store       |
+---------+----------+     | (raft/consensus)       |
          |                +-----------+------------+
          |                            |
          |                            v
          |                    +------------------+
          |                    | Watch / cache    |
          |                    +------------------+
          |                            |
          v                            v
+--------------------+     +------------------------+
| Boot: fetch state  | <-- | Remote store           |
+--------------------+     +------------------------+
```

Description:
- A distributed store (etcd/consul) is the source of truth. Nodes commit updates via RPC and watch the store for changes. Local caches are optional and usually derived from watch streams.
- This model is strong for coordinated placement because there is a single authoritative state machine, but it shifts reliability and durability to the external system.
- Offline or partitioned nodes need explicit policies; otherwise they may not be able to perform critical operations.

Performance vs others:
- Write throughput: lower than local WAL/snapshots due to network and consensus overhead.
- Read/startup: slower and dependent on network/quorum availability.
- CPU: higher from RPC, serialization, and coordination logic.

Readability/understandability vs others:
- Conceptually simple in terms of a single source of truth.
- Operational behavior is harder to reason about because failure modes are distributed.
- More moving parts and more infrastructure knowledge required.

Pros (relative to all other designs):
- Strong coordination and consistent placement decisions.
- Simplifies conflict resolution logic in the application layer.
- Offloads durability, snapshots, and compaction to the external system.

Cons (relative to all other designs):
- Highest operational burden and dependency risk.
- Least offline-friendly and most sensitive to network outages.
- Higher latency for state changes compared to local persistence.

ECS-CRDT architecture using an external store:

```text
+------------------------+     +-----------------------+
| ECS World (entities)   |<--->| CRDT Merge System     |
| Node, Service, Placement|     +-----------------------+
+-----------+------------+                |
            |                             v
            |                      +-------------+
            |                      | Gossip I/O  |
            |                      +-------------+
            |
            v
+------------------------+     +------------------------+
| RPC to external store  | --> | Cluster KV (raft)      |
| Watch for updates      |     | etcd/consul            |
+------------------------+     +------------------------+
boot: fetch -> ECS world
```

## Placement Claim System (ECS-CRDT + WAL)

Diagram:

```text
-----------------------+     +------------------------+
| NodeMeta (CRDT LWW)   |<--->| ServiceSpec (CRDT LWW) |
| cpu/mem/disk/platform |     | constraints/replicas  |
+-----------+-----------+     +-----------+------------+
            |                           |
            v                           v
      +-------------------------------+ 
      | PlacementScoringSystem        |
      | - filter eligible nodes       |
      | - compute deterministic score |
      +---------------+---------------+
                      |
             if self is best
                      v
      +-------------------------------+     +-----------------------+
      | Claim/Lease Update            | --> | WAL Append (SetPlacement)
      | - lease_epoch, expires_at     |     | + CRDT update          |
      +---------------+---------------+     +-----------------------+
                      |
                      v
            +-------------------+
            | Gossip deltas     |
            +-------------------+
                      |
                      v
            +-------------------+
            | Systemd reconcile |
            +-------------------+
```

Description:
- Services can have replicas and may move freely to rebalance. The claim system treats each desired replica as a schedulable slot that can be claimed by the best node at any moment, then re-claimed if a better candidate appears.
- Each node computes the same deterministic score from shared CRDT state. If it is the highest-scoring eligible node for a replica, it claims that replica by writing a durable placement entry to the WAL and gossips the update.
- Leases prevent rapid flapping and allow fast recovery: if a node stops renewing its lease, another node can claim the replica once the lease expires.

Components (ECS):
- NodeMeta (CRDT LWW): cpu_free, mem_free, disk_free, platform, last_seen, meta_version.
- ServiceSpec (CRDT LWW): env/args/platform constraints, replica count, placement constraints, spec_version.
- ServicePlacement (CRDT Register): service_id, replica_id, node_id, lease_epoch, expires_at, score, basis_meta_version, hlc.
- ServiceRuntime (local only): systemd unit state and last health info.

Claim and merge rules:
- Candidate eligibility: platform matches, sufficient resources, node is healthy (last_seen within threshold).
- Deterministic score: weighted sum of available resources and load; tie-break by node_id.
- Claim: if self is best and placement is missing/expired or significantly worse, write SetPlacement to WAL and update CRDT.
- Merge: highest lease_epoch wins; if tied, newer HLC wins; then higher score; then node_id.

Replica handling:
- Each replica is a separate placement record (service_id + replica_id).
- The scoring system attempts to avoid co-locating replicas on the same node unless the cluster is undersupplied.
- Rebalancing can be triggered by score drift, node meta changes, or explicit policy changes.

WAL entries:
- SetPlacement(service_id, replica_id, node_id, lease_epoch, expires_at, score, basis_meta_version, hlc)
- ReleasePlacement(service_id, replica_id, node_id, reason, hlc) (optional)

Operational notes:
- Hysteresis prevents thrash: require a minimum score improvement or lease expiry to override an existing placement.
- Placement decisions should ignore very stale NodeMeta to avoid poor placement during partitions.

## Migration Sketch (Current -> ECS-CRDT + WAL)

Goal: move from a monolithic node + in-memory CRDT store to ECS-CRDT with WAL-backed service specs and placements, while keeping behavior stable and testable.

High-level phases:

1) Introduce ECS scaffolding without behavior changes
- Add an ECS world and entity IDs, but keep the existing `Node` API as a facade.
- Mirror current node fields into ECS components (identity, HLC, store, buffers).
- Keep the current WAL logic intact (knowledge only) while ECS becomes a storage refactor.

2) Split CRDT state into explicit components
- Move service version tracking into `ServiceSpec` + `ServiceVersion` components.
- Add `NodeMeta` as a CRDT component for cluster-wide node resource view.
- Update gossip encode/decode to read/write component deltas instead of the monolithic store.

3) Expand WAL to typed entries (v2)
- Define versioned WAL entry types: `PutServiceSpec`, `SetPlacement`, `UpdateNodeMeta`.
- Implement replay to rebuild ECS state deterministically on boot.
- Add a bounded compaction/snapshot mechanism to cap replay time.

4) Introduce placement and reconciliation systems
- Add `PlacementScoringSystem` and `PlacementClaimSystem` with leases.
- Add `SystemdReconcileSystem` driven by desired placement state.
- Gate placement claims with feature flags or config to limit risk.

5) Remove or minimize legacy paths
- Deprecate legacy `Node` state fields and move all logic to ECS systems.
- Drop redundant on_deploy hooks once reconciliation is stable.
- Clean up old CRDT store code paths and keep compatibility shims only if needed.

## Migration Plan (Step-by-Step)

Step 1: ECS world and facade
- Create an ECS world module and entity allocator.
- Wrap the current `Node` with `(world, node_entity)` to avoid large call-site changes.
- Add tests to ensure `Node.tick` behavior and gossip output remain unchanged.

Step 2: Componentization of service state
- Add `ServiceSpec`, `ServiceVersion`, `ServiceRuntime` components.
- Port `ServiceStore` read/write paths to use components while preserving HLC ordering.
- Update gossip codec to emit deltas from component tables.

Step 3: WAL v2 and replay
- Define a versioned entry header and typed payloads.
- Add replay that populates ECS components; keep backward compatibility with existing WAL.
- Implement compaction (e.g., snapshot + truncate).

Step 4: Placement claims + leases
- Add `ServicePlacement` component with replica_id.
- Implement deterministic scoring and lease renewal.
- Add Hysteresis thresholds and staleness checks to avoid thrash.

Step 5: Systemd reconciliation + cleanup
- Switch to reconcile mode: run services iff placement == self.
- Remove legacy on_deploy code paths after stability.
- Validate with simulation tests and add recovery tests for WAL v2.

Risk controls:
- Keep feature flags for placement and WAL v2 during rollout.
- Ensure tests cover replay, gossip convergence, and rebalancing.
- Roll out in phases to keep behavior stable and reversible.

## Compatibility Matrix (WAL v1 vs v2)

```text
WAL Version | Reader v1 | Reader v2 | Writer v1 | Writer v2
----------- |---------- |---------- |---------- |----------
v1          | OK        | OK        | OK        | N/A
v2          | FAIL      | OK        | N/A       | OK
Mixed (v1+v2)| N/A      | OK        | N/A       | OK
```

Notes:
- v2 reader must detect v1 entries and replay them for backward compatibility.
- v1 reader cannot read v2 entries; use a version flag and refuse with a clear error.
- During migration, run v2 reader + v1 writer, then switch to v2 writer once stable.

## Test Migration Guidance

Goals: preserve current behavior, add durability tests for new WAL types, and ensure convergence under rebalancing.

Recommended sequence:
1) Baseline tests: keep `tests/simulation.zig` passing while introducing ECS facade.
2) WAL replay tests: extend WAL tests to include v2 entries and mixed logs.
3) Gossip delta tests: validate that component-based deltas converge as the old store did.
4) Placement tests: add a focused unit test for deterministic scoring and tie-breaking.
5) Systemd reconcile tests: add a small fake executor to assert start/stop calls.

Suggested additions:
- `tests/wal_v2.zig`: replay mixed v1/v2 logs, corruption handling, version mismatch.
- `tests/placement.zig`: deterministic winner and lease expiry behavior.
- `tests/rebalance.zig`: replicas move when meta changes and converge cluster-wide.

## Proposed File Layout (ECS-CRDT + WAL)

```text
src/
  ecs/
    world.zig              # entity allocator + component storage
    components.zig         # NodeMeta, ServiceSpec, ServicePlacement, ...
    systems/
      gossip.zig           # encode/decode deltas, apply merges
      placement.zig        # scoring, claims, leases
      reconcile.zig        # systemd desired vs actual
      replay.zig           # WAL replay into ECS world
  db/
    wal.zig                # v1 + v2 support, entry encoding/decoding
    wal_types.zig          # typed entry schemas
  sync/
    crdt.zig               # CRDT helpers (LWW, registers, merge)
    hlc.zig
  node/
    facade.zig             # Node API wrapper around ECS world
  schema/
    service.zig
  systemd.zig
tests/
  wal_v2.zig
  placement.zig
  rebalance.zig
  simulation.zig
```

## Cross-Design Summary (Performance and Readability)

Performance (best to worst):
- Write throughput: WAL > CAS ~ Snapshot > DB > External store
- Cold start: Snapshot > CAS > WAL (with compaction) > DB > External store
- Runtime overhead: WAL ~= Snapshot < CAS < DB < External store

Readability/understandability (best to worst):
- Snapshot > WAL > CAS > DB > External store

Notes:
- WAL remains the best overall fit for Myco's constraints, especially if paired with periodic compaction.
- CAS + manifest is a strong alternative when service specs are large and benefit from dedup and rollback.
- Snapshot-only works if you can tolerate state loss between intervals.
- External store is powerful for centralized coordination but requires operational maturity.
