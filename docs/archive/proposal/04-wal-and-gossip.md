# Proposal (Page 4/5): WAL v2, Replay, and Gossip Encoding

This page explains two critical parts of the architecture:

1) **WAL v2** as the durable source of local intent and decisions.
2) **Gossip encoding** as the bandwidth‑bounded mechanism for CRDT convergence.

Both parts must respect Myco’s original constraints: bounded memory, fixed packet size, deterministic behavior, and simulation friendliness.

## 1) WAL v2: what it must do (and what it must not do)

The WAL’s job is to preserve **intent** and **decisions** across restarts:

- service spec changes (deploy/update/delete)
- replica count changes
- placement claims (including lease epochs)
- optional: operator overrides (pin/unpin)

The WAL should *not* attempt to be a full database:

- it should not support arbitrary queries
- it should not store high‑frequency telemetry unless necessary
- it should not require large allocations

Instead, WAL is an append‑only history that replays into ECS tables.

## 2) WAL v2 entry format

We want an entry format that is:

- versioned
- self‑describing (kind + length)
- corruption detectable (CRC)
- skippable (unknown kinds can be skipped safely)

### WAL entry layout (ASCII)

```text
+--------------------------------------------------------------------------------+
| EntryHeader                                                                     |
|--------------------------------------------------------------------------------|
| magic (u32) | wal_version (u8) | kind (u8) | flags (u16) | payload_len (u32)    |
|--------------------------------------------------------------------------------|
| key_hi (u64) | key_lo (u64)    | hlc_version (u64) | payload_crc32 (u32)       |
|--------------------------------------------------------------------------------|
| reserved (u32)                                                                |
+--------------------------------------------------------------------------------+
| payload bytes (payload_len)                                                    |
+--------------------------------------------------------------------------------+
```

Notes:
- `key_hi/key_lo` allow us to encode domain keys without allocating (e.g., ServiceId, ReplicaKey).
- `hlc_version` is the event’s version. For local events, we mint it; for imported events, we keep it.
- `payload_crc32` is computed over payload bytes.

### Example kinds
- `PutServiceSpecSummary`
- `PutServiceSpecBlob` (optional, if storing full spec in WAL)
- `DeleteServiceSpec`
- `SetPlacement`
- `ReleasePlacement`
- `OperatorOverride` (pin/unpin)

## 3) WAL commit discipline: “durable before side effects”

The safety rule is simple:

- If an action can start/stop a service (systemd side effect), then the decision that caused it must already be durable.

### Commit flow (flow diagram)

```text
create Event (e.g., SetPlacement)
  |
  v
WAL.append(event) + fsync
  |
  v
apply event to ECS tables
  |
  v
emit effects (gossip delta, reconcile intent)
  |
  v
execute effects (send packet, systemd)
```

Why this order matters:
- If the process crashes after WAL append but before reconcile, replay will restore the placement and reconcile will resume.
- If the process crashes after reconcile but before WAL append, the service may start but the placement is not durable; on restart, the node may stop it unexpectedly or duplicate work.

## 4) WAL replay model

Replay must be deterministic and easy to test:

- Start from an empty world.
- Iterate entries in order.
- Verify CRC; stop or skip based on corruption policy.
- Apply event semantics to tables (same `applyEvent` used at runtime).

### Replay architecture (ASCII)

```text
+--------------------+      +----------------------+      +----------------------+
| WAL segments/files | ---> | Replay iterator      | ---> | applyEvent(world, e) |
| (bounded)          |      | - verify header/crc  |      | - update tables      |
+--------------------+      | - decode payload     |      | - mark dirty         |
                             +----------+----------+      +----------+-----------+
                                        |                           |
                                        v                           v
                               +-----------------+         +---------------------+
                               | Replay metrics  |         | World ready for tick|
                               +-----------------+         +---------------------+
```

Replay policy choices:
- For development/simulation: stop on corruption and report.
- For production: stop at first corrupt entry (treat as truncated), then continue running.

## 5) Compaction and snapshots (keeping replay bounded)

Without compaction, replay time grows with the WAL.

A practical approach:

- WAL is segmented (e.g., `wal.0001`, `wal.0002`, …)
- Periodically, create a snapshot of current tables.
- Write a new segment containing a “checkpoint snapshot entry” (or write a separate snapshot file).
- Remove old segments up to the checkpoint.

### Compaction diagram (ASCII)

```text
before:
  wal.0001 + wal.0002 + wal.0003 + wal.0004

compact:
  snapshot(world) -> snap.bin
  write checkpoint -> wal.0005
  delete old segments

after:
  snap.bin + wal.0005
```

This keeps replay bounded to “load snapshot + replay recent tail.”

## 6) Gossip encoding: component sections, stable ordering

The gossip goal is to transmit CRDT deltas within a 1024‑byte packet.

We use a sectioned payload:

- Each section corresponds to one component kind (NodeMeta, ServiceSpecSummary, Placement).
- Each section is encoded in a compact, columnar way.
- Optional lightweight compression is applied if it helps.

This matches patterns already visible in the repo (section markers + columnar encoding in `src/node/codec.zig`).

### Packet payload layout (ASCII)

```text
+--------------------------------------------------------------------------------+
| Packet.payload (<= 944 bytes usable; depends on header)                         |
|--------------------------------------------------------------------------------|
| SectionHeader(kind=NodeMeta, len=...) | section bytes                           |
|--------------------------------------------------------------------------------|
| SectionHeader(kind=ServiceSpec, len=...) | section bytes                         |
|--------------------------------------------------------------------------------|
| SectionHeader(kind=Placement, len=...) | section bytes                           |
+--------------------------------------------------------------------------------+
```

SectionHeader can be as small as:
- `kind (u8)` + `len (u16)`

## 7) Delta encoding strategy

For each section, we want two properties:

- **monotonic, stable streams** (better compression)
- **cheap decode** (no heap)

### 7.1 IDs

Encode IDs as varints. If entries are sorted by ID, encode deltas:

- first ID as varint
- subsequent IDs as delta varints

### 7.2 HLC versions

HLC versions pack `wall_ms` and `logical`.

Columnar encoding works well:

- stream of wall values (delta-of-delta with zigzag)
- stream of logical values (varint)

This pattern is already used in the existing codec to maximize packing.

### Section flow diagram

```text
Dirty keys -> stable order -> encode ids -> encode versions -> (optional) encode payload summary
  |
  v
if compressed_len < raw_len: send compressed
else: send raw
```

## 8) Spec blob fetch path (keeping packets small)

Because specs may contain env vars and args, they can exceed “reasonable gossip payload size.”

We therefore replicate:

- spec summary (hash, replicas, platform, version)

…and only fetch full spec blobs when needed:

- when placement says this node should run replica
- or when an operator requests details

### Fetch architecture (ASCII)

```text
+----------------------+     +----------------------+     +----------------------+
| ServiceSpecSummary   |     | Need full spec?      |     | Spec blob store       |
| (hash+version)       |---->| if missing locally   |---->| by hash (validated)   |
+----------+-----------+     +----------+-----------+     +----------+-----------+
           |                          |                            |
           |                          v                            |
           |                +------------------+                   |
           |                | SpecRequest msg  |-------------------+
           |                +------------------+        peer reply
           v
  gossip keeps moving even without blobs
```

The request/reply protocol can reuse existing “request by id” patterns, but keyed by hash.

Security note:
- If env vars contain secrets, blob fetch should include redaction/encryption policy.

## 9) Why this design is “best of both”

- ECS tables give us stable, columnar data sources for delta generation.
- Reducer discipline keeps merge/apply logic deterministic and testable.
- WAL guarantees durability for intent and placement decisions.
- Sectioned payloads keep packets compact and improve compressibility.

Page 5 describes placement (replicas + rebalancing), reconcile behavior, failure modes, and a test strategy that keeps these properties honest.
