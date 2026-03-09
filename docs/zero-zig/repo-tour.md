# Repo Tour

This is a short map of the Myco repo with focus points for new readers.

## Top-level

- README.md
  - Quick project summary, build steps, and test targets.
- build.zig and build.zig.zon
  - Zig build graph and dependencies.
- docs/
  - System overview, quickstart, and operational notes.
- src/
  - All production code.
- tests/
  - Unit tests and simulation harnesses.

## Key code directories

- src/main.zig
  - Program entry point and CLI. Starts the daemon and config.
- src/node.zig
  - Core node logic: gossip, CRDT updates, missing set, outbox.
- src/sync/
  - CRDT store and Hybrid Logical Clock (HLC).
  - Files: sync/crdt.zig, sync/hlc.zig.
- src/db/
  - WAL implementation in db/wal.zig.
- src/net/
  - Identity, handshake, and packet handling.
- src/node/codec.zig
  - Encoding/decoding gossip payloads and digest sections.
- src/schema/service.zig
  - Wire format for service payloads.
- src/core/config.zig
  - ServiceConfig parsing and persistence logic.
- src/systemd.zig and src/engine/systemd.zig
  - Systemd unit generation and service application.
- src/api/
  - API server and handlers.

## Where to start for a feature

- Gossip and convergence
  - src/node.zig, src/node/codec.zig, src/sync/crdt.zig
- WAL durability
  - src/db/wal.zig, docs/operational-notes.md
- Service deployment
  - src/schema/service.zig, src/core/config.zig, src/systemd.zig
- Identity and networking
  - src/net/handshake.zig, src/net/identity.zig
- Simulation behavior
  - tests/simulation.zig

## Useful cross references

- docs/architecture.md for big-picture flow.
- docs/GLOSSARY.md for terms like WAL, HLC, CRDT.
- docs/ENV.md for environment toggles.
