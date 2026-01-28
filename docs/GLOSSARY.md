# Glossary

- Node: running daemon instance (`src/node.zig`).
- Service: deployable payload (`src/schema/service.zig`); ids must be non-zero.
- CRDT: last-write-wins store (`src/sync/crdt.zig`).
- HLC: Hybrid Logical Clock for version ordering (`src/sync/hlc.zig`).
- Gossip: UDP exchange of digests and deltas (`src/node.zig`, `src/net/gossip.zig`).
- Transport: TCP control plane + handshake (`src/net/transport.zig`).
- WAL: append-only log buffer for durability simulation (`src/db/wal.zig`).
- UDS: Unix domain socket API server (`MYCO_UDS_PATH`, default `/tmp/myco.sock`).
- State dir: `MYCO_STATE_DIR` (default `/var/lib/myco`); contains `node.key`, `peers.list`, and `services/*.json`.
