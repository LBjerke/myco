# Quickstart

A quick path to build and run Myco locally.

## Prerequisites

- Zig 0.15.2
- POSIX shell (Linux/macOS)

## Build

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast
```

Output: `./zig-out/bin/myco`

## Run

```bash
./zig-out/bin/myco
```

The daemon will:
1. Initialize the frozen allocator
2. Set up the WAL (creates `data/wal/` if missing)
3. Replay any existing events from the WAL
4. Freeze the allocator
5. Enter the tick loop

## Test

```bash
# All unit tests
zig build test

# Simulation tests
zig build test-sim

# Test utilities
zig build test-utils

# E2E tests
zig build e2e

# Full CI suite
zig build ci
```

## Environment Variables

The following are currently supported (Phase 1):

| Variable | Default | Description |
|----------|---------|-------------|
| `MYCO_WAL_PATH` | `data/wal/` | WAL directory path |

## Troubleshooting

- Build fails? Run `zig build` to see errors
- Need help? See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)

## What's Implemented

- Frozen allocator (zero-allocation after init)
- WAL with replay
- ECS storage
- Event types and reducer protocol
- HLC timestamps

## What's Next (Phase 2)

- Gossip protocol / network sync
- CLI commands
- API server
- systemd integration
