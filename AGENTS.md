# Repository Guidelines

## Project Structure & Module Organization
- `src/` houses daemon subsystems: gossip/transport (`net`, `node.zig`, `packet.zig`), CRDT/clock (`sync`), persistence (`db/wal.zig`), orchestration/API (`engine`, `api`), CLI glue (`cli`), and simulation helpers (`sim`).
- `tests/` contains unit/integration specs plus the simulation entry at `tests/simulation.zig`.
- `docs/` covers architecture, quickstart, testing, and operational notes; record rationale there when behavior shifts.
- `build.zig`/`build.zig.zon` drive the build graph; `Makefile` offers simulation shortcuts; `ci/` holds lightweight tooling.
- Artifacts land in `zig-out/bin`; caches stay under `zig-cache` (set `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` if `$HOME` is sandboxed).

## Build, Test, and Development Commands
```
zig build -Doptimize=ReleaseSmall          # build myco -> zig-out/bin/myco
zig build test-crdt                        # CRDT/clock/gossip correctness (fast)
zig build test-cli                         # CLI scaffolding checks
zig build test-engine                      # systemd/nix glue tests
zig build test-sim                         # full simulations (slow)
make sim-50-realworld | make sim-20-pi-wifi # targeted simulation profiles
nix develop                                # optional dev shell with pinned Zig/crypto
```
- Run from repo root; prefer ReleaseSmall for reproducible binaries; simulations take time.

## Coding Style & Naming Conventions
- Run `zig fmt` on Zig files you touch; keep new files ASCII.
- Defaults: 4-space indent, types in TitleCase, functions/vars in lowerCamel, tests as `test "descriptive case" {}`.
- Keep helpers near their subsystem (e.g., net helpers in `src/net`); avoid cross-package drive-bys.

## Testing Guidelines
- Touch gossip/CRDT/packet code → `zig build test-crdt` + one simulation; engine/systemd → `zig build test-engine`; CLI → `zig build test-cli`.
- Simulations emit logs under `zig-cache`; attach failing seeds/profiles to PRs.
- On macOS sandboxed setups, export `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache` before builds/tests.

## Commit & Pull Request Guidelines
- Use short, imperative commits (e.g., `engine: tighten restart delay`); group related work, avoid mega-commits.
- PRs should include scope summary, expected vs actual for fixes, tests/simulations run or skipped, and risk notes for packet layout/WAL format/network timers.
- Link issues when applicable; include logs or screenshots for CLI behavior changes.

## Security & Configuration Tips
- Packet size is fixed at 1024 bytes and service schema must fit the payload (~920 bytes); call out anything that alters wire compatibility.
- Avoid leaving plaintext debug flags (e.g., `MYCO_PACKET_PLAINTEXT`) enabled by default; document new ports/env vars in PRs and `docs/`.
