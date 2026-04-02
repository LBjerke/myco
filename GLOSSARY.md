# Glossary

This document defines technical terms used throughout the Myco project. If you encounter an unfamiliar term, start here.

## Core Concepts

### CRDT (Conflict-free Replicated Data Type)

A data structure that can be replicated across multiple computers in a network, where replicas can be updated independently and concurrently without coordination between the replicas, and conflicts are automatically resolved.

Think of it like a Google Doc where multiple people can edit offline, and when they reconnect, the system automatically figures out the "correct" final version.

**Myco usage**: CRDTs let all nodes in the mesh agree on things like "which node owns which service" without needing a central coordinator.

**Learn more**:
- Research: [Conflict-free Replicated Data Types](https://arxiv.org/abs/1805.06358) - Comprehensive survey (Preguiça, Baquero, Shapiro, 2018)
- Original Paper: [CRDTs SSS 2011](https://inria.hal.science/hal-00932836/file/CRDTs_SSS-2011.pdf) - First formal definition (Shapiro et al., 2011)

### ECS (Entity Component System)

A way to organize data and logic in a game/engine-style architecture:

- **Entity**: Just an ID (like a reference number), not actual data
- **Component**: Raw data attached to an entity (e.g., "this node has 4 CPU cores")
- **System**: Code that processes entities with certain components

**Myco usage**: Instead of one giant struct per node, Myco stores data in separate "tables" (components). This is more memory-efficient and makes it easier to add new data types.

### WAL (Write-Ahead Log)

A persistent record of every change to the system's state, written *before* the change is applied.

Think of it like an astronaut's flight log: before taking any action, you write down what you're about to do. If something goes wrong, you can replay the log to reconstruct what happened.

**Myco usage**: The WAL ensures that if a node crashes and restarts, it can "replay" all the deployment decisions it made and restore the correct state.

**Learn more**:
- Specification: [PostgreSQL WAL Documentation](https://www.postgresql.org/docs/current/wal-intro.html) - Industry-standard reference implementation
- Tutorial: [WAL Internals](https://www.postgresql.org/docs/17/wal-internals.html) - Detailed technical explanation

### Gossip Protocol

A way for nodes to share information by periodically exchanging messages with random peers, like gossip spreading through a social network.

Each node tells a few neighbors, those neighbors tell a few more, and eventually everyone knows everything.

**Myco usage**: Nodes gossip about node health, service placements, and cluster state. It's resilient to network partitions—information still spreads even if some links break.

**Learn more**:
- Research: [How robust are gossip-based communication protocols?](https://www.cs.cornell.edu/lorenzo/papers/p14-alvisi.pdf) - Analysis of gossip protocol robustness (Alvisi et al.)
- Dissertation: [Gossip-based Protocols for Large-scale Distributed Systems](https://www.inf.u-szeged.hu/~jelasity/dr/doktori-mu.pdf) - Comprehensive survey (Jelasity, 2013)

### HLC (Hybrid Logical Clock)

A way to assign timestamps that combine:
- Real wall-clock time (like looking at your watch)
- A logical counter (like incrementing a version number)

This gives you ordering guarantees without requiring all machines to have perfectly synchronized clocks.

**Myco usage**: When two nodes disagree about who owns a service replica, HLC timestamps determine which "wins" in a deterministic, fair way.

**Learn more**:
- Research: [Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases](https://cse.buffalo.edu/~demirbas/publications/hlc.pdf) - Original HLC paper (Kulkarni et al., 2014)
- Tutorial: [Hybrid Logical Clocks](https://sookocheff.com/post/time/hybrid-logical-clocks/) - Kevin Sookocheff's explanation

---

## Data Structures & Patterns

### LWW (Last-Write-Wins)

A simple conflict resolution strategy: whichever write has the newest timestamp wins.

**Myco usage**: Used for node metadata (like available CPU/memory). If two nodes report different values, the one with the newer HLC timestamp "wins".

### Deterministic Register

Like LWW, but with explicit tie-breakers when timestamps are equal (e.g., "lower node ID wins").

**Myco usage**: Used for service placement to prevent "flapping" where ownership bounces back and forth between nodes.

### SoA (Structure of Arrays)

An alternative to "Array of Structures" (AoS):

- **AoS**: `[{x: 1, y: 2}, {x: 3, y: 4}]` — grouped by entity
- **SoA**: `{ x: [1, 3], y: [2, 4] }` — grouped by field

SoA is often faster because you can iterate over just one field (e.g., all X coordinates) without loading the others.

**Myco usage**: ECS component tables use SoA layout for cache efficiency.

### Tombstone

A marker indicating that a piece of data has been deleted, kept around so other nodes know to delete it too during synchronization.

**Myco usage**: When a service is deleted, Myco doesn't just remove it—it writes a tombstone so the deletion propagates to all nodes via gossip.

### Dirty Tracking

Keeping track of which data has changed since last exported/synced, so you only send the differences (deltas), not the whole dataset.

**Myco usage**: Each node tracks which nodes, services, and placements have changed since last gossip, then sends only those deltas in the 1024-byte packet.

---

## Myco-Specific Terms

### Node

A single machine running the Myco daemon. Could be a Raspberry Pi, a homelab server, or any POSIX-compliant system.

### Service

A deployment unit that Myco manages. Defined by a service spec (environment variables, arguments, resource limits) and can have multiple replicas.

### Replica

An instance of a service running on a node. If a service has 3 replicas, Myco ensures roughly 3 instances are running across the cluster.

### ReplicaKey

The unique identifier for a specific replica: `(ServiceId, ReplicaId)`. For example, `service=1000, replica=2` identifies the third replica of service 1000.

### Placement

Which node a replica is assigned to. Myco's placement system automatically decides where to run services based on available resources and constraints.

### NodeMeta

Data about a node that gets shared across the cluster:
- Available CPU, memory, disk
- Platform type (Linux, ARM, etc.)
- Labels for filtering
- Last seen timestamp (for health)

### ServiceSpec

The definition of a service:
- How many replicas
- Resource requirements
- Environment variables
- Command-line arguments

### ServiceRuntime

Local-only runtime information about a running service:
- Is it currently running?
- What's the systemd unit name?
- When did it last start/crash?

### Reducer

A function that takes the current state plus an event, and produces a new state. No side effects allowed—it only transforms data.

**Myco usage**: All state changes happen through reducers, making the system testable—you can feed events to a reducer and check the result without running a full cluster.

### Effect

Something that happens *after* state is updated: sending a network packet, writing a file, calling systemd, etc.

**Myco usage**: Reducers produce effects, which the imperative shell executes. This keeps the "pure" logic separate from "impure" I/O.

---

## Technical Terms

### Tick Loop

The main event loop that runs continuously, processing:
- Timer events
- Incoming network packets
- API/CLI commands

### Delta

The difference between two states, as opposed to the full state. Sending deltas is more bandwidth-efficient than sending everything.

### Fanout

The number of peers a node gossips with each cycle. Higher fanout = faster propagation but more network traffic.

### Backpressure

When a system slows down input processing because it can't keep up with output. Prevents memory exhaustion under load.

### Compaction

The process of cleaning up old WAL entries (replacing them with a "snapshot" of the current state) to prevent the log from growing forever.

---

## See Also

- [README.md](../README.md) — Main project documentation
- [docs/archive/proposal/01-overview.md](../docs/archive/proposal/01-overview.md) — Detailed architecture explanation
- [docs/archive/proposal/03-state-model-and-crdt.md](../docs/archive/proposal/03-state-model-and-crdt.md) — Deep dive into state model
