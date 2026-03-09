# Tests

## Smallest Relevant Set
- CRDT/sync changes: `zig build test-crdt` (`tests/sync_crdt.zig`).
- CLI scaffolding: `zig build test-cli` (`tests/cli.zig`).
- Engine (systemd/nix): `zig build test-engine` (`tests/engine.zig`).
- Unit tests: `zig build test-units` (roots at `src/lib.zig`).
- Simulations: `zig build test-sim` or a filtered run like `zig build sim-50`.

## Full Pipeline
- `go run ./ci/main.go` (full CI flow; see `GEMINI.md` for verification expectations).

## Smoke / Scripts
- `scripts/two_nodes.sh` - local multi-node smoke test.
- `scripts/run_realworld_tests.sh` - real-world simulation profiles.
- `scripts/cluster_smoke.sh` - podman-based cluster smoke.

## Notes
- On sandboxed macOS, set `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to a writable folder.
- Simulation knobs live in `docs/ENV.md`.
