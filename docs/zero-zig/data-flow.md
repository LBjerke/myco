# Data Flow Guide

This doc connects modules into end-to-end flows so you can reason about the system without knowing Zig.

## Boot and initialization

1) src/main.zig creates the daemon context and Node.
2) Node.initWithOptions in src/node.zig sets up identity, WAL, HLC, and the service store.
3) WAL recover replays the last known knowledge counter (today only that counter is durable).
4) The node enters its tick loop and processes incoming packets.

Key files:
- src/main.zig
- src/node.zig
- src/db/wal.zig

## Gossip and convergence

1) Node.tick processes missing items and inbound packets.
2) Incoming digests are decoded in src/node/codec.zig.
3) The CRDT store in src/sync/crdt.zig updates versions and records deltas.
4) The node periodically gossips deltas and samples to peers via packets.

Key files:
- src/node.zig
- src/node/codec.zig
- src/sync/crdt.zig

## Service deployment path

1) A service is injected or received via gossip and written to the local store.
2) The on_deploy callback runs when a service is new or updated.
3) systemd unit files are generated in src/systemd.zig using ServiceConfig.

Key files:
- src/schema/service.zig
- src/core/config.zig
- src/systemd.zig

## Simulation and testing

- tests/simulation.zig spins up many nodes with a network simulator.
- Each NodeWrapper wraps a real Node and calls tick with simulated packets.
- This is the best place to understand convergence behavior under failures.

Key files:
- tests/simulation.zig
- tests/sync_crdt.zig
- tests/engine.zig

## How to follow a change

Example: "change gossip payload"

1) Find encoding in src/node/codec.zig.
2) Follow decode path in src/node.zig (handleSyncControlHeaders).
3) Check CRDT store in src/sync/crdt.zig for version tracking.
4) Update tests in tests/sync_crdt.zig and tests/simulation.zig.
