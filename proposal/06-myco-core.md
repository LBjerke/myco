# Proposal (Addendum): myco-core (Side-effect-free Core Library)

This addendum captures a concrete v1 shape for a separate `myco-core` Zig
library. It is side-effect-free, does zero allocations at runtime, and emits
effects for an external system (WAL/gossip/runner) to execute.

## Goals

- side-effect-free core with deterministic state updates
- zero runtime allocations (all storage is fixed at init/compile-time)
- ECS-style tables for cluster state (nodes/jobs/placements)
- CRDT merge rules for replicated components
- placement/claim logic with leases
- emit bounded lists of effects for an outer system to execute

## Non-goals

- WAL and gossip encoding (handled by separate libraries)
- systemd or runtime management (outer system responsibility)

## High-level shape

```text
+----------------------------------------------------------------------------------+
|                                 External System                                  |
| (WAL / Gossip / Runner / API)                                                    |
|                                                                                  |
|  Proposals / Deltas / Time                                                       |
|    - UpdateNodeMeta                                                              |
|    - PutJobSpec / DeleteJob                                                      |
|    - MergeDelta                                                                  |
|    - Tick(now_ms)                                                                |
|                     |                                                            |
|                     v                                                            |
|  +--------------------------- myco-core (pure) -------------------------------+  |
|  | Public API:                                                                |  |
|  |   applyProposal()  mergeDelta()  tick()  exportDeltas()                     |  |
|  |                                                                            |  |
|  |  +-------------------+   +-------------------+   +----------------------+  |  |
|  |  | ECS Tables        |   | CRDT Merge        |   | Placement / Claims   |  |  |
|  |  | - NodeMeta        |<->| - LWW (HLC)       |<->| - eligibility        |  |  |
|  |  | - JobSpecSummary  |   | - placement merge|   | - score + tie-break  |  |  |
|  |  | - Placement       |   | - tombstones     |   | - leases + renewals  |  |  |
|  |  +-------------------+   +-------------------+   +----------------------+  |  |
|  |            |                         |                        |             |  |
|  |            v                         v                        v             |  |
|  |                     Effects (bounded list)                                   |  |
|  |     - StartJob / StopJob / EmitDelta / ExternalUpdate                         |  |
|  +---------------------------------------------------------------------------+  |
|                     |                                                            |
|                     v                                                            |
|  Side effects executed by external system                                        |
+----------------------------------------------------------------------------------+
```

## Core data model (v1)

- IDs: `NodeId` and `JobId` are `u64`.
- NodeMeta (replicated, LWW by HLC):
  - `cpu_free_pct: u8` (0..100)
  - `mem_free_bytes: u64`
  - `disk_free_bytes: u64`
  - `platform_mask: u64`
  - `labels_mask: u64`
  - `version: Hlc`
- JobSpec summary (replicated, LWW by HLC):
  - `job_id: JobId`
  - `replicas: u16`
  - `platform_mask: u64`
  - `cpu_req_pct: u8`
  - `mem_req_bytes: u64`
  - `disk_req_bytes: u64`
  - `version: Hlc`
- Placement (replicated, deterministic merge):
  - `job_id: JobId`
  - `replica_id: u16`
  - `node_id: NodeId`
  - `lease_epoch: u32`
  - `expires_at_ms: u64`

## Limits (compile-time)

All tables and buffers are fixed-size using compile-time constants:

- `MAX_NODES`
- `MAX_JOBS`
- `MAX_REPLICAS_TOTAL`
- `MAX_DIRTY_*`
- `MAX_EFFECTS`
- `MAX_EVENTS`
- `MAX_DELTAS`

This keeps runtime allocation at zero. Any overflow is reported via a bounded
`Effects` result with an `overflow` flag so the caller can take action.

## Proposals and effects (v1)

Inputs to the core:

- `UpdateNodeMeta { node_id, cpu_free_pct, mem_free_bytes, disk_free_bytes, platform_mask, labels_mask }`
- `PutJobSpec { job_id, replicas, platform_mask, cpu_req_pct, mem_req_bytes, disk_req_bytes }`
- `DeleteJob { job_id }`

Outputs from the core (side-effect descriptions only):

- `StartJob { job_id, replica_id, node_id }`
- `StopJob { job_id, replica_id, node_id }`
- `EmitDelta { delta }`
- `ExternalUpdate { kind, payload }` (generic hook)

## Compile-time vs startup-time sizing

Compile-time sizing is simpler and produces smaller/faster code, but changing
limits requires rebuilds. Startup-time sizing is more flexible but adds an init
API for passing buffers and requires careful capacity checks. Either approach
keeps zero runtime allocations; compile-time was selected for v1 simplicity.

## Heterogeneous node capacities (if startup-time sizing is used later)

Different nodes can run with different capacities, but convergence requires each
node to hold the full cluster state. If a node cannot, it must surface an
overflow condition and the cluster should treat it as under-capacity. If
heterogeneous sizes are allowed, add a limits handshake and enforce a minimum
required capacity for healthy operation.
