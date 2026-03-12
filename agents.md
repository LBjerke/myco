# Myco Project Guide for AI Agents

This document provides essential information for AI agents working on the Myco project. It covers the tech stack, build/test procedures, architecture, and constraints.

---

## Project Overview

**Myco** is a **Self-Healing Mesh Orchestrator** written in Zig. It aims to turn a fleet of small machines (Raspberry Pis, homelab nodes) into a self-healing mesh. It persists deployment intent in a WAL, uses CRDTs with HLC for conflict resolution, and is designed to run with **zero allocations in the hot path**.

> **Status**: Phase 1 complete. Working on networking (Phase 2).

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| **Language** | Zig 0.15.2 |
| **Build System** | Zig build system (`build.zig`) |
| **Runtime** | No runtime dependencies (standalone binary) |
| **Storage** | ECS (Entity Component System) - custom implementation |
| **Persistence** | WAL (Write-Ahead Log) - custom segment-based implementation |
| **Clock** | HLC (Hybrid Logical Clock) - custom implementation |
| **Testing** | Zig test framework + custom E2E test harness |

### No External Dependencies

Myco has **zero external dependencies** at runtime. It uses only:
- Zig standard library
- POSIX APIs (for file I/O, networking)

This ensures minimal footprint and portability.

---

## Build, Run, and Test (via Makefile)

All operations are handled through the Makefile. The project uses `zig` as the underlying build tool.

### Build Commands

```bash
# Build the project (debug mode)
make build
# Or directly: zig build

# Build in release mode (optimized)
make build-release
# Or directly: zig build -Doptimize=ReleaseFast
```

**Output**: Binary is placed at `zig-out/bin/myco`

### Run Commands

```bash
# Run the application
make run
# Or directly: ./zig-out/bin/myco
```

The daemon will:
1. Initialize the frozen allocator
2. Set up the WAL (creates `data/wal/` if missing)
3. Replay any existing events from the WAL
4. Freeze the allocator
5. Enter the tick loop

> **Note**: Currently takes no arguments - edit `src/main.zig` to change WAL path or add CLI options.

### Test Commands

```bash
# Run unit tests
make test
# Or directly: zig build test

# Run simulation tests
make test-sim
# Or directly: zig build test-sim

# Run test utility tests
make test-utils
# Or directly: zig build test-utils

# Run all test suites (unit + sim + utils)
make test-all

# Run end-to-end tests
make test-e2e

# Run E2E tests with verbose output
make test-e2e-verbose

# Run E2E tests with custom binary path
make test-e2e-binary

# Run ALL tests including E2E
make test-all-including-e2e
```

### Development Commands

```bash
# Format source code (Zig fmt)
make format

# Check code formatting without modifying
make check-format

# Generate HTML documentation
make docs

# Run static analysis
make analyze
```

### Maintenance Commands

```bash
# Clean build artifacts
make clean

# Install binary to /usr/local/bin
make install

# Uninstall binary
make uninstall

# Show version info
make version

# Show git status
make git-status

# Show recent commits
make git-log
```

### Quick Reference

| Task | Command |
|------|---------|
| Build | `make build` |
| Build release | `make build-release` |
| Run | `make run` |
| Test all | `make test-all` |
| Test + E2E | `make test-all-including-e2e` |
| Format code | `make format` |
| Clean | `make clean` |
| Help | `make help` |

---

## Architecture

### High-Level Architecture

```
+-----------------------------------------------------------------+
|                         Myco Daemon                              |
|                                                                  |
|  +-----------------+   +---------------------+   +-------------+ |
|  | Inputs          |   | Functional Core     |   | Imperative  | |
|  | - timers        |-->| (reducers/systems) |-->| Shell       | |
|  | - packets       |   |                     |   | (I/O)       | |
|  | - CLI commands |   |  +---------------+  |   |             | |
|  +-----------------+   |  | ECS World     |  |   | +---------+ | |
|                        |  | (SoA tables)  |  |   | | WAL     | | |
|                        |  +-------+-------+  |   | +---------+ | |
|                        |          |          |   |             | |
|                        |          v          |   | +---------+ | |
|                        |  +---------------+  |   | | Effects | | |
|                        |  | Effects       |  |   | +---------+ | |
|                        |  | - send gossip |  |   +-------------+ |
|                        |  | - systemd ops |  |                   |
|                        |  +---------------+  |                   |
|  +-----------------+   +---------------------+                   |
|  | Outputs          |                                             |
|  | - gossip pkts   |                                             |
|  | - systemd units |                                             |
|  +-----------------+                                             |
+-----------------------------------------------------------------+
```

### Core Components

| Component | File | Description |
|-----------|------|-------------|
| **Entry Point** | `src/main.zig` | Tick loop skeleton, initialization |
| **WAL** | `src/db/wal.zig` | Write-ahead log with segment-based storage and replay |
| **ECS World** | `src/ecs/world.zig` | Entity Component System storage tables |
| **Event Types** | `src/core/event.zig` | Typed event definitions |
| **Reducer Protocol** | `src/core/reducer.zig` | Functional core for applying events with effects |
| **Frozen Allocator** | `src/util/allocator.zig` | Zero-allocation runtime after initialization |
| **HLC** | `src/net/hlc.zig` | Hybrid Logical Clock for ordering |
| **Limits** | `src/util/limits.zig` | System constants and bounds |

### Data Flow (Current)

1. Load config
2. Initialize WAL
3. Replay WAL events to reconstruct ECS world state
4. Freeze allocator (no more heap allocations!)
5. Enter tick loop

### Key Design Patterns

1. **ECS Storage**: Data stored in fixed-capacity, columnar (SoA - Structure of Arrays) tables
2. **Functional Core**: Reducers take `(world, input) -> (world', effects)` - no I/O in reducers
3. **Imperative Shell**: Handles WAL writes, network I/O, systemd calls
4. **CRDTs**: Uses LWW (Last-Write-Wins) registers and deterministic registers for conflict resolution
5. **Event Sourcing**: All state changes recorded as events in WAL

### Project Structure

```
myco-greenfield/
├── src/
│   ├── main.zig           # Entry point, tick loop
│   ├── lib.zig            # Library exports
│   ├── core/
│   │   ├── event.zig      # Event type definitions
│   │   └── reducer.zig    # Reducer protocol
│   ├── db/
│   │   └── wal.zig        # Write-Ahead Log
│   ├── ecs/
│   │   └── world.zig      # ECS storage
│   ├── net/
│   │   └── hlc.zig        # Hybrid Logical Clock
│   └── util/
│       ├── allocator.zig  # Frozen allocator
│       └── limits.zig     # System constants
├── tests/
│   ├── simulation.zig     # Simulation tests
│   ├── test_utils.zig     # Test utilities
│   ├── allocator_test.zig # Allocator tests
│   ├── runner.zig         # Test runner
│   └── e2e/               # End-to-end tests
├── proposal/              # Architecture proposals
├── features/             # Feature tracking
├── Makefile              # Build automation
├── build.zig             # Zig build config
├── README.md             # Main documentation
├── GLOSSARY.md           # Technical terms
└── TROUBLESHOOTING.md    # Common issues
```

---

## Constraints

### Critical Design Constraints

| Constraint | Description | Rationale |
|------------|-------------|-----------|
| **Packet Size** | Fixed at **1024 bytes** | Network efficiency for small devices |
| **Zero Allocations** | Hot path must be allocation-free after init | Predictable performance, no GC |
| **HLC Semantics** | Wall clocks not compared directly | Clock skew tolerance |
| **Bounded Memory** | Fixed tables and bounded buffers | Predictable resource usage |
| **Deterministic Identity** | Node IDs and tie-breakers are deterministic | Reproducible behavior |
| **Minimal Footprint** | No heavy embedded DB dependencies | Runs on Raspberry Pis |

### Non-Goals

- **Not** a general-purpose ECS framework
- **Not** linearizable "one true" state (eventually consistent)
- **Not** perfect systemd orchestration on day one

### Phase Roadmap

| Phase | Status | Description |
|-------|--------|-------------|
| **Phase 1: Core Infrastructure** | ✅ Complete | Frozen allocator, WAL, ECS, Events, HLC, Reducers |
| **Phase 2: Networking** | 🔄 In Progress | Gossip protocol, node-to-node communication, delta encoding |
| **Phase 3: CLI & API** | ⏳ Planned | CLI commands, API server, config parsing |
| **Phase 4: Orchestration** | ⏳ Planned | systemd unit generation, service deployment, health monitoring |
| **Phase 5: Production Hardening** | ⏳ Planned | Security, WAL compaction, logging, metrics, simulation testing |

---

## Key Terms (Quick Reference)

| Term | Definition |
|------|------------|
| **CRDT** | Conflict-free Replicated Data Type - auto-merging data structure |
| **ECS** | Entity Component System - data-oriented storage pattern |
| **WAL** | Write-Ahead Log - durable event log with replay |
| **HLC** | Hybrid Logical Clock - timestamp combining wall clock + logical counter |
| **LWW** | Last-Write-Wins - conflict resolution strategy |
| **SoA** | Structure of Arrays - columnar data layout for cache efficiency |
| **Reducer** | Pure function: `(world, event) -> (world', effects)` |
| **Effect** | Side effect produced by reducer (network, filesystem, systemd) |
| **Tick Loop** | Main event loop processing timers, packets, commands |

---

## Troubleshooting Quick Links

- **Common issues**: See [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- **Technical terms**: See [`GLOSSARY.md`](./GLOSSARY.md)
- **Detailed architecture**: See [`proposal/01-overview.md`](./proposal/01-overview.md)
- **State model & CRDTs**: See [`proposal/03-state-model-and-crdt.md`](./proposal/03-state-model-and-crdt.md)

---

## For AI Agents Working on This Codebase

### When Making Changes

1. **Preserve zero-allocation guarantee**: Any new code in hot paths must not allocate
2. **Keep packet size under 1024 bytes**: Gossip deltas must fit
3. **Use HLC for ordering**: Never compare wall clocks directly
4. **Write events, not direct state mutations**: Go through reducers
5. **Test determinism**: Simulation tests should produce identical results

### Code Style

- Use Zig's native style (run `make format` before committing)
- Follow the existing patterns in `src/core/reducer.zig` for new reducers
- Add events to `src/core/event.zig` for new state changes

### Testing

- Unit tests: Add inline tests in source files
- Simulation tests: Add to `tests/simulation.zig`
- E2E tests: Add to `tests/e2e/test-cli.sh`

### Getting Context

To understand any subsystem:
1. Start with the proposal documents in `proposal/`
2. Check `GLOSSARY.md` for terminology
3. Read the main source file for that component
4. Look at tests for usage examples
