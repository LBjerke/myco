# Testing Matrix

What to run, when, and what it covers.

## Targets
- CRDT sync (fast): `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache zig build test-crdt`
  - Covers HLC ordering, CRDT store updates, digest encoding/decoding.
- CLI scaffolding: `zig build test-cli`
  - Exercises CLI wiring and basic command surfaces.
- Engine/systemd/nix glue: `zig build test-engine`
  - Validates packaging and engine helpers; good sanity before distro changes.
- Full simulations (slow): `zig build test-sim`
  - End-to-end gossip under loss/latency/partitions using the deterministic simulator.
  - Use specific profiles via Makefile:
    - `make sim-20-pi-wifi` (moderate)
    - `make sim-50-realworld` (heavier)
- Formatting: `zig fmt` on touched Zig files (enforced manually).

## When to Run
- CRDT changes (ordering/delta logic/packet digest): run `test-crdt` and at least one simulation profile.
- Network/packet/crypto changes: run `test-crdt` + `test-sim` (or a `sim-*` make target).
- CLI/engine/systemd changes: run `test-cli` and `test-engine`.
- Release or perf-sensitive changes: run `test-crdt`, `test-cli`, `test-engine`, and one simulation.

## Interpreting Results
- Simulation logs live under `zig-cache` when tests fail; they include packet counters and delivery stats.
- Packet size invariants: `src/packet.zig` enforces 1024 bytes at compile time; breaks will surface during build.
- Service payload invariants: `src/schema/service.zig` compile-time checks payload size fits the packet.

## Tips
- Set `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` to writable paths in sandboxed macOS to avoid cache failures.
- Use `-ODebug` via `make sim-50-realworld-debug` to get richer assertions at the cost of speed.
- Optional TUI while running simulations: set `MYCO_SIM_TUI=1` (tick refresh via `MYCO_SIM_TUI_REFRESH`, event buffer via `MYCO_SIM_TUI_EVENTS`) to watch node status and packet flow live.
- Opt-in slow TUI demo: `MYCO_SIM_TUI_DEMO=1 zig build sim-8-tui-demo` (runs a slowed 8-node simulation for easier visualization).
