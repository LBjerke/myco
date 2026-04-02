# Contributing to Myco

Myco is a zero-dependency Zig daemon with a custom ECS, WAL, and HLC. This guide covers expectations for contributors.

## Prerequisites

- Toolchain: Zig 0.15.2
- Platform: POSIX shell
- Style: Run `zig build format` before committing. Keep lines under 100 chars, functions under 70 lines.

## Build and Test Locally

```bash
# Build debug
zig build

# Build release
zig build -Doptimize=ReleaseFast

# Run all tests
zig build test

# Run simulation tests
zig build test-sim

# Run test utils
zig build test-utils

# Run E2E tests
zig build e2e

# Full CI suite
zig build ci
```

## Development Workflow

1. Create a feature branch, keep commits focused
2. Run `zig build ci` before submitting changes
3. Preserve invariants:
   - Zero allocations in hot path after init
   - Packet size constraint: 1024 bytes max (for future networking)
   - HLC semantics: never compare wall clocks directly
4. Add tests for new functionality

## Required Checks

All PRs must pass:
```bash
zig build ci
```

This runs: fmt → lint → build → test → test-sim → test-utils → complexity → duplication → tiger-style → e2e

## Code Style

- Follow Zig idioms (run `zig build format`)
- Keep functions under 70 lines (enforced by `zig build tiger-style`)
- Keep lines under 100 characters
- Add assertions - aim for ≥2 per function

## Key Files

| Component | File |
|-----------|------|
| ECS storage | `src/ecs/world.zig` |
| WAL | `src/db/wal.zig` |
| Events | `src/core/event.zig` |
| Reducers | `src/core/reducer.zig` |
| Frozen allocator | `src/util/allocator.zig` |
| HLC | `src/net/hlc.zig` |

## Documentation

Update docs when changing interfaces or operational steps:
- `docs/architecture.md` - Architecture details
- `docs/TESTS.md` - Testing procedures
- `TROUBLESHOOTING.md` - Common issues
- `AGENTS.md` - Quick reference for AI agents
