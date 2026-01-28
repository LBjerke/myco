# Quickstart

A terse path to build and run Myco locally.

## Prerequisites
- Zig 0.15.x (the repo pins a version in `build.zig.zon`).
- POSIX shell; on macOS set `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache` to avoid cache permission issues.
- Optional: `nix develop` for a pre-baked env with Zig and crypto libs.

## Build
```bash
zig build -Doptimize=ReleaseSmall
```
Output: `./zig-out/bin/myco` (packed daemon with gossip + API).

## Run a Single Node (local dev)
```bash
# From repo root
./zig-out/bin/myco
```
Useful env knobs:
- `MYCO_GOSSIP_FANOUT` (default 4) to tune rumor fanout.
- `MYCO_PACKET_PLAINTEXT=1` to force plaintext packets where applicable.
- Packet crypto (simulator/transport): `MYCO_PACKET_KEY`, `MYCO_PACKET_EPOCH`, and optional `MYCO_PACKET_KEY_PREV`, `MYCO_PACKET_EPOCH_PREV`, `MYCO_GOSSIP_PSK`.

## Two-Node Flow (toy)
Run two terminals:
```bash
# Terminal A
zig build -Doptimize=ReleaseSmall
./zig-out/bin/myco &
NODE_A_ID=$(./zig-out/bin/myco id 2>/dev/null || echo "node-a")

# Terminal B
./zig-out/bin/myco &
./zig-out/bin/myco peer add node-a <A_IP>
./zig-out/bin/myco deploy demo-service node-a   # adjust CLI arguments to your topology
```
Notes:
- The CLI surface may differ based on your branch; align with current `src/cli` behavior.
- For real packet crypto, ensure matching packet keys/epochs on both sides.

## Quick Checks
- CRDT tests (fast): `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache zig build test-crdt`
- Sim smoke (slow): `make sim-20-pi-wifi` or `make sim-50-realworld` (ReleaseFast).
- Metrics endpoint: once running, hit the minimal HTTP server (see `docs/api.md`) to confirm the node is alive.
