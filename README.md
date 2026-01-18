# Myco: Self-Healing Mesh Orchestrator

Myco is a tiny (<500KB) Zig binary that turns a fleet of small machines (Raspberry Pis, homelab nodes, etc.) into a self-healing mesh. It gossips deployments using CRDTs (now driven by Hybrid Logical Clocks), persists intent in a WAL, and ships its own lightweight API/server for simulations and control.

## What’s Inside
- Deterministic node identity + gossip transport (`src/net`, `src/node.zig`).
- Last-write-wins CRDTs with HLC-based conflict resolution (`src/sync`).
- WAL-backed durability for deployments (`src/db/wal.zig`).
- Simulation harness to stress partitions, loss, crashes (`tests/simulation.zig`).
- Minimal API/server and orchestration helpers (`src/api`, `src/engine`).

## Build & Run
Prereqs: Zig 0.15.x (or the project’s pinned version), POSIX environment.

```bash
# From the repo root
zig build -Doptimize=ReleaseSmall
./zig-out/bin/myco daemon
```

The `daemon` command boots the gossip daemon, WAL, and API server. Most options are in `src/main.zig`; tweak env vars (e.g., `MYCO_PACKET_PLAINTEXT`) as needed.

## Tests
The build script exposes grouped steps:
```bash
# CRDT sync tests (fast)
ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache zig build test-crdt

# CLI scaffolding tests
zig build test-cli

# Engine (systemd/nix) tests
zig build test-engine

# Full simulations (slow)
zig build test-sim
# or filtered runs via the provided steps: zig build sim-50, sim-50-heavy, sim-100, etc.
```
On macOS sandboxed setups, setting `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to a writable folder avoids cache permission issues.

## Deploying a Node (single host)
```bash
# Build
zig build -Doptimize=ReleaseSmall

# Initialize data dirs (example)
mkdir -p /var/lib/myco

# Run the daemon
./zig-out/bin/myco daemon

# Example: add a peer and deploy
# myco peer add <PUBKEY_HEX> <IP:PORT>
# myco deploy
```
`myco deploy` deploys the service defined in the current directory.
In production you’d likely wrap this with a systemd unit (see `src/engine/systemd.zig` for the generated template).

### Quick Two-Node Mesh (dev example)
```bash
# Terminal A (Node A)
zig build -Doptimize=ReleaseSmall
./zig-out/bin/myco daemon &
# Grab Node A's public key
NODE_A_PUBKEY=$(./zig-out/bin/myco pubkey)
# Start a second node with a different port and state dir
MYCO_PORT=7778 MYCO_STATE_DIR=/tmp/node_b MYCO_UDS_PATH=/tmp/myco_b.sock ./zig-out/bin/myco daemon &

# Terminal B (Node B)
# Add Node A as a peer (replace <A_IP> with reachable address, e.g. 127.0.0.1)
MYCO_STATE_DIR=/tmp/node_b ./zig-out/bin/myco peer add $NODE_A_PUBKEY 127.0.0.1:7777

# Deploy a service to the mesh (run from a directory with a valid myco service config)
MYCO_UDS_PATH=/tmp/myco_b.sock ./zig-out/bin/myco deploy
```
This assumes your environment plumbs addresses and uses the built-in gossip transport; adapt the CLI invocations to your current `net/handshake` behavior.

### Systemd Unit (template)
`src/engine/systemd.zig` generates a hardened unit. A minimal hand-written unit could look like:
```
[Unit]
Description=Myco Mesh Node
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/myco
Restart=always
RestartSec=5
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```
Adjust `ExecStart`, capabilities, and data directories to your deployment layout; prefer the generated template for full hardening flags.

## Roadmap to Production-Ready
- **Security hardening**: end-to-end packet MAC/crypto enabled by default, key rotation, authenticated control plane.
- **Persistence & recovery**: WAL compaction, snapshotting, configurable retention, disk corruption guards.
- **Observability**: structured logging, metrics endpoints, trace IDs, and per-node health surfacing.
- **Operational tooling**: CLI UX polish, peer lifecycle management, graceful shutdown/restart hooks.
- **Simulation coverage**: CI matrix for high-loss/partition scenarios, surge tests, larger node-count runs.
- **Resource constraints**: backpressure and queue sizing tuned for low-memory devices; bounded gossip fanout.
- **Upgrades**: versioned packet formats, migration paths for on-disk state.
- **Packaging**: reproducible builds, container images, and signed release artifacts.

## Project Layout
- `src/` – daemon, network, CRDTs, engine, API.
- `tests/` – unit tests, simulations, CLI/engine checks.
- `build.zig` – build/test graph wiring the above.
