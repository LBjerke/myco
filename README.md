# Myco: Self-Healing Mesh Orchestrator

Myco is a **work-in-progress** Zig project that aims to turn a fleet of small machines (Raspberry Pis, homelab nodes, etc.) into a self-healing mesh. It persists deployment intent in a WAL, uses CRDTs with HLC for conflict resolution, and is designed to run with zero allocations in the hot path.

> **Status**: Phase 1 complete. Working on networking (Phase 2).

## What Works So Far

- **Frozen Allocator** — Zero-allocation runtime after initialization
- **WAL (Write-Ahead Log)** — Event persistence with replay on boot
- **ECS World** — Full component storage (Node, NodeMeta, NodeHealth, ServiceSpec, ServiceRuntime, ServicePlacement)
- **HLC Timestamp** — Hybrid Logical Clock for ordering
- **Event Types** — Typed events for state changes
- **Reducer Protocol** — Functional core for applying events with effects

## What's Inside (Implemented)

- `src/main.zig` — Entry point with tick loop skeleton
- `src/db/wal.zig` — WAL with segment-based storage and replay
- `src/ecs/world.zig` — ECS storage tables
- `src/core/event.zig` — Event type definitions
- `src/core/reducer.zig` — Reducer protocol with effects system
- `src/util/allocator.zig` — Frozen allocator (no allocations after init)
- `src/util/limits.zig` — System constants
- `src/net/hlc.zig` — Hybrid Logical Clock implementation

## What's Not Implemented Yet

- Gossip protocol / network sync between nodes
- CLI commands (`myco deploy`, `myco peer add`, `myco pubkey`)
- systemd integration / service deployment
- Simulation harness
- API server

See [Roadmap](#roadmap) for what's planned.

## How It Works (Current)

```
+-----------------------------------------------------------------+
|                         Your Machine                             |
|                                                                  |
|   +-------------+                                                |
|   |   (future)  |  <- CLI/API (not yet implemented)            |
|   |   CLI/API   |                                                |
|   +------+------+                                                |
|          |                                                       |
|          v                                                       |
|   +-------------------------------------------------------+     |
|   |                    Tick Loop                            |     |
|   |  (runs continuously, processes all inputs)             |     |
|   +-----------------------+-------------------------------+     |
|                           |                                      |
|          +----------------+----------------+                     |
|          v                v                v                      |
|   +-------------+  +-------------+  +-------------+              |
|   |     WAL     |  |  ECS World  |  |  (future)   |              |
|   |  (durable   |  |   (state   |  |   Gossip    |              |
|   |   log)      |  |   storage) |  |  (network)  |              |
|   +------+------+  +------+------+  +------+------+              |
|          |                |                |                      |
|          +----------------+----------------+                      |
|                           v                                       |
|                  +-----------------+                              |
|                  |  (future)       |  <- Systemd deployment      |
|                  |  Systemd/Deploy |                              |
|                  +-----------------+                              |
+-----------------------------------------------------------------+
```

**Current data flow:**
1. Load config
2. Initialize WAL
3. Replay WAL events to reconstruct ECS world state
4. Freeze allocator (no more heap allocations!)
5. Enter tick loop (currently just sleeps)

## Build & Run

Prereqs: Zig 0.14.x or later, POSIX environment.

```bash
# Build
zig build

# Run (starts the daemon)
./zig-out/bin/myco
```

The daemon will:
1. Initialize the frozen allocator
2. Set up the WAL (creates `data/wal/` if missing)
3. Replay any existing events from the WAL
4. Freeze the allocator
5. Enter the tick loop (currently just prints status and sleeps)

### With Custom WAL Directory

```bash
# Use a custom WAL directory
./zig-out/bin/myco
# Currently takes no arguments - edit src/main.zig to change WAL path
```

> **Need help?** See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)

## Tests

```bash
# Run all tests
zig build test
```

## Roadmap

### Phase 1: Core Infrastructure ✅ Complete
- [x] Project scaffold
- [x] Frozen allocator
- [x] WAL with replay
- [x] ECS storage
- [x] Event types
- [x] HLC timestamps
- [x] Reducer protocol (applying events to state)
- [x] Component expansion (more data types)

### Phase 2: Networking (Planned)
- [ ] Gossip protocol implementation
- [ ] Node-to-node communication
- [ ] Delta encoding for efficient sync
- [ ] Packet size optimization (1024-byte target)

### Phase 3: CLI & API (Planned)
- [ ] CLI commands (deploy, peer add, pubkey, etc.)
- [ ] API server
- [ ] Configuration file parsing

### Phase 4: Orchestration (Planned)
- [ ] systemd unit generation
- [ ] Service deployment
- [ ] Placement decisions
- [ ] Health monitoring

### Phase 5: Production Hardening
- [ ] Security (encryption, authentication)
- [ ] WAL compaction / snapshotting
- [ ] Structured logging
- [ ] Metrics and observability
- [ ] Simulation testing

## Project Layout

```
myco-greenfield/
├── src/
│   ├── main.zig           # Entry point, tick loop
│   ├── core/
│   │   ├── event.zig      # Event type definitions
│   │   └── reducer.zig    # Reducer protocol (functional core)
│   ├── db/
│   │   └── wal.zig        # Write-Ahead Log
│   ├── ecs/
│   │   └── world.zig      # ECS storage
│   ├── net/
│   │   └── hlc.zig        # Hybrid Logical Clock
│   └── util/
│       ├── allocator.zig  # Frozen allocator
│       └── limits.zig      # Constants
├── tests/                  # (not yet populated)
├── features/               # Feature tracking
├── proposal/               # Architectural proposals
├── README.md
├── GLOSSARY.md
└── TROUBLESHOOTING.md
```

## Learning More

- [GLOSSARY.md](./GLOSSARY.md) — Definitions of technical terms
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — Common issues and solutions
- [features/README.md](./features/README.md) — Implemented features
- [proposal/01-overview.md](./proposal/01-overview.md) — Architecture vision
