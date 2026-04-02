# Myco Agent Guide

Self-Healing Mesh Orchestrator in Zig. Zero runtime dependencies. Zero allocations in hot path.

## Quick Commands

| Task | Command |
|------|---------|
| Build | `zig build` |
| Build release | `zig build -Doptimize=ReleaseFast` |
| Run | `./zig-out/bin/myco` |
| Full test suite | `zig build ci` |
| Format | `zig build format` |
| Lint | `zig build lint` |
| Tiger Style | `zig build tiger-style` |

## Tech Stack

- **Zig 0.15.2** - Language
- **No dependencies** - Zig stdlib + POSIX only
- **ECS** - Custom entity component system
- **WAL** - Write-ahead log with replay
- **HLC** - Hybrid Logical Clock

## Core Files

| Component | File |
|-----------|------|
| Entry point | `src/main.zig` |
| ECS storage | `src/ecs/world.zig` |
| WAL | `src/db/wal.zig` |
| Events | `src/core/event.zig` |
| Reducers | `src/core/reducer.zig` |
| Frozen allocator | `src/util/allocator.zig` |
| HLC | `src/net/hlc.zig` |

## Design Constraints

| Constraint | Limit |
|------------|-------|
| Packet size | 1024 bytes max |
| Allocations | Zero after init (hot path) |
| Function length | ≤70 lines |
| Line length | ≤100 chars |

## Required Checks Before PR

```bash
zig build ci
```

This runs: fmt → lint → build → test → test-sim → test-utils → complexity → duplication → tiger-style → e2e

## Key Patterns

1. **Write events, not direct mutations** - All state changes go through reducers
2. **No I/O in reducers** - Reducers are pure: `(world, event) → (world', effects)`
3. **Use HLC for ordering** - Never compare wall clocks directly
4. **Keep deltas under 1024 bytes** - Network efficiency for small devices

## Phase Status

| Phase | Status |
|-------|--------|
| 1: Core Infrastructure | ✅ Complete |
| 2: Networking | 🔄 In Progress |
| 3: CLI & API | ⏳ Planned |
| 4: Orchestration | ⏳ Planned |

## Docs

- [docs/architecture.md](docs/architecture.md) - Detailed architecture
- [docs/TESTS.md](docs/TESTS.md) - Testing procedures
- [GLOSSARY.md](GLOSSARY.md) - Technical terms
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Common issues
