# Proposal (Page 5/5): Placement (Replicas + Rebalance), Reconcile, Failure Modes, and Testing

This page focuses on the “hard parts” of the system: replica placement, movement/rebalancing, and the systemd reconcile loop. It also outlines the failure model and a test plan that gives high confidence that the architecture actually converges under partitions and restarts.

## 1) Placement: requirements and invariants

Placement must satisfy several constraints simultaneously:

- Services have `replicas >= 1`.
- Each replica should be placed on a “best” node given current NodeMeta and ServiceSpec constraints.
- Replicas may move freely to rebalance, but should not oscillate unnecessarily.
- Multiple nodes may compute placement concurrently; the system must converge.
- Side effects (starting/stopping services) must be safe under temporary disagreement.

A good way to think about placement is as two layers:

1) **Desired ownership (replicated)**: `ServicePlacement` records in CRDT state.
2) **Local execution (side effect)**: systemd reconcile obeys the desired ownership when leases permit.

## 2) Replica model: treat each replica as a schedulable slot

We represent each replica as a stable key:

- `ReplicaKey = (ServiceId, ReplicaId)`

The cluster’s state includes at most `MAX_TOTAL_REPLICAS` such keys (bounded by limits).

This simplifies reasoning:

- Placement decisions are per-replica.
- Rebalancing affects a single replica at a time.
- Gossip deltas remain compact.

## 3) Eligibility filtering

Before scoring, we exclude nodes that cannot run the replica.

Eligibility rules (example):

- `node.platform` matches `spec.platform_mask`.
- `node.last_seen_ms` is within TTL (node considered “alive”).
- `node.mem_free`, `cpu_free`, `disk_free` meet minimum requirements.
- optional: labels/taints/tolerations.

Filtering is deterministic and depends only on replicated state.

## 4) Scoring and deterministic winner selection

A simple deterministic scoring function often works well:

- `score = w_mem * mem_free + w_cpu * cpu_free + w_disk * disk_free - w_load * running_replicas`

Tie-break:

- If scores are equal, choose the lowest `NodeId` (or lowest hash). This ensures all nodes compute the same winner.

### Anti-affinity for replicas

We try to spread replicas across distinct nodes.

Practical approach:

- First pass: prefer nodes that do not already own a replica of the same service.
- Second pass (if undersupplied): allow co-location.

This can be implemented deterministically as part of scoring:

- subtract a penalty if `node` already hosts a replica for the same `ServiceId`.

## 5) Leases, epochs, and hysteresis (preventing thrash)

Without a stability mechanism, “free movement” can become oscillation.

We therefore introduce leases:

- Each placement record includes `lease_epoch` and `expires_at_ms`.
- The owner renews the lease periodically.

And hysteresis:

- A node only steals a replica if:
  - the lease is expired, OR
  - the new score exceeds the old score by a threshold, OR
  - the old owner is stale/unhealthy.

### Placement claim flow (flow diagram)

```text
for each ReplicaKey:
  cur <- placement[ReplicaKey]
  if cur exists and not expired:
      if improvement < hysteresis and owner healthy: do nothing
  compute winner by deterministic scoring
  if winner == self:
      emit SetPlacement(lease_epoch+1, expires_at)
      (durable via WAL)
```

### Placement merge rule reminder

Even if two nodes claim at once, CRDT merge chooses a single winner deterministically:

1) higher lease_epoch
2) newer HLC
3) higher score
4) lower NodeId

This guarantees convergence of the placement record, even under concurrent claims.

## 6) Placement as an internal service (ASCII)

```text
+--------------------------------------------------------------------------------+
| Placement Service                                                              |
|--------------------------------------------------------------------------------|
| Inputs (replicated):                                                           |
|  - NodeMetaTable (cpu/mem/disk/platform/last_seen/version)                     |
|  - ServiceSpecTable (hash/replicas/platform/constraints/version)               |
|  - PlacementTable (current owner/lease/version)                                |
|                                                                                |
| Deterministic pipeline:                                                        |
|  eligibility filter -> scoring -> tie-break -> hysteresis -> emit events       |
|                                                                                |
| Outputs:                                                                       |
|  - SetPlacement events (durable WAL)                                           |
|  - dirty placement keys (for gossip)                                           |
+--------------------------------------------------------------------------------+
```

## 7) Reconcile: making systemd match desired state safely

The reconcile loop is responsible for the actual side effects:

- start/stop/restart units
- write unit files
- manage env vars and args

Reconcile must be:

- **idempotent**: running it twice produces the same final state.
- **rate-limited**: avoid restart storms.
- **lease-aware**: do not run a service unless we currently own the replica lease.

### Desired vs actual

Desired state is derived from replicated placement:

- desired replicas = all `ReplicaKey` where `placement.node_id == self` and `lease valid`.

Actual state is observed locally:

- cached runtime component + optional systemd query.

The reconcile plan is a diff:

- start missing desired units
- stop units no longer desired
- restart units if spec hash changed

### Reconcile flow diagram

```text
placements -> desired set (for self)
  |
  v
load spec blobs (by hash; fetch if missing)
  |
  v
compute diff(desired, runtime)
  |
  v
execute actions with backoff
  |
  v
update ServiceRuntime component
```

### Reconcile as a service (ASCII)

```text
+--------------------------------------------------------------------------------+
| Reconcile Service                                                             |
|--------------------------------------------------------------------------------|
| Inputs:                                                                       |
|  - PlacementTable (replicas owned by self; lease must be valid)               |
|  - ServiceSpecSummary (hash/version)                                          |
|  - Spec blobs (env/args/systemd config)                                       |
|  - ServiceRuntime (local cached state)                                        |
|                                                                                |
| Outputs:                                                                      |
|  - systemd unit changes (start/stop/restart)                                  |
|  - updated ServiceRuntime                                                     |
|  - metrics/logs                                                               |
+--------------------------------------------------------------------------------+
```

## 8) Failure modes and mitigations

### 8.1 Network partitions

Symptoms:
- NodeMeta staleness causes bad placement.
- Concurrent claims increase.

Mitigations:
- TTL on NodeMeta; do not place onto stale nodes.
- Leases: expired leases allow safe takeover.
- Hysteresis: reduces oscillation after partitions heal.

### 8.2 Clock skew

Symptoms:
- HLC wall time diverges.

Mitigations:
- HLC observe/next rules maintain monotonicity.
- Avoid comparing wall clocks directly; only compare HLC versions.

### 8.3 Disk full / WAL append failure

Symptoms:
- cannot make durable claims.

Mitigations:
- Fail closed for side effects: do not start services based on non-durable placements.
- Surface an error via API/metrics.
- Trigger compaction if possible.

### 8.4 Conflicting spec blobs

Symptoms:
- spec hash mismatch or corrupted blob.

Mitigations:
- hash validation on load.
- request blob from another peer.
- refuse to run service if spec cannot be validated.

### 8.5 Thrash under noisy telemetry

Symptoms:
- placements moving too frequently.

Mitigations:
- hysteresis thresholds.
- minimum lease duration.
- scoring smoothing (e.g., EWMA of free resources).

## 9) Testing strategy (how we know this works)

The best-of-both design is chosen largely because it is testable:

- reducers/systems are deterministic and I/O-free
- WAL replay is just applying a sequence of events
- placement decisions can be tested as pure functions over NodeMeta/Spec/Placement

### Test layers

1) Unit tests (fast)
- HLC ordering and observe rules.
- LWW merge for NodeMeta/ServiceSpec.
- Placement merge tie-break rules.
- Scoring determinism.
- Lease expiry and hysteresis behavior.

2) WAL tests (fast)
- append/replay round-trip for each entry kind.
- corruption handling (CRC mismatch) behavior.
- mixed segments + compaction.

3) Gossip codec tests (medium)
- encode/decode sections round-trip.
- bounded packet size with worst-case dirty sets.
- compression effectiveness on stable ordered deltas.

4) Simulation tests (slow)
- partitions, loss, latency, crashes.
- restart nodes and verify replay restores placements/specs.
- ensure placements converge and reconcile doesn’t thrash.

### Properties to assert

- Convergence: after sufficient ticks, all nodes agree on placements and spec hashes.
- Safety: a node does not run a replica without owning a valid lease.
- Durability: after restart, owned placements/specs are restored and reconcile resumes.
- Stability: replica movement rate stays below a configured maximum under steady conditions.

## 10) Why the experts choose this “best of both” implementation

- ECS gives the storage layout needed for efficient delta generation and bounded memory.
- Functional reducers give replay/debug/test simplicity, which is critical when you add placement and durability.
- CRDT semantics provide eventual convergence without introducing a heavyweight consensus dependency.
- WAL provides local durability without a DB.

If you implement only one of these styles, you usually sacrifice either modular growth (pure reducer with one big state blob) or determinism/testability (framework-like ECS with scattered side effects). The combined approach aims to keep both.

End of proposal.
