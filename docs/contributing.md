# Contributing to Myco

Myco is a tiny Zig daemon that gossips CRDT state, persists intent in a WAL, and ships a built-in API plus simulator. This guide captures the expectations for contributors so changes stay safe and reproducible.

## Prerequisites
- Toolchain: Zig 0.15.x (pinned via `build.zig.zon`). The Nix flake (`nix develop`) provides a working environment with Zig and crypto libs.
- Platform: POSIX shell. macOS users should set `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache` to avoid sandbox/cache issues.
- Style: Run `zig fmt` on Zig sources you touch. Keep new files ASCII-only and prefer small, focused changes.

## Build and Test Locally
- Build the daemon: `zig build -Doptimize=ReleaseSmall` (outputs `zig-out/bin/myco`).
- Targeted tests (fast):
  - CRDT/sync: `ZIG_GLOBAL_CACHE_DIR=zig-cache ZIG_LOCAL_CACHE_DIR=zig-cache zig build test-crdt`
  - CLI scaffolding: `zig build test-cli`
  - Engine/systemd/nix glue: `zig build test-engine`
- Simulations (slow, but catch gossip/partition regressions):
  - `zig build test-sim` for the full suite.
  - `make sim-50-realworld` or `make sim-20-pi-wifi` for specific profiles.
- If you touch gossip, CRDT ordering, packet layout, or encryption, please run the CRDT tests plus at least one simulation profile.

## Development Workflow
- Create a feature branch, keep commits narrow, and include a short rationale in commit messages.
- Preserve invariants:
  - `src/packet.zig` must stay exactly 1024 bytes (`comptime` check will fail otherwise).
  - `src/schema/service.zig` must fit inside the packet payload (current hard limit 920 bytes).
  - CRDT ordering is last-write-wins via Hybrid Logical Clocks; never compare wall clocks directly.
- Add or update tests when fixing bugs or changing behavior. Simulation logs in `zig-cache` help explain nondeterministic failures.
- Update docs when interfaces or operational steps change (including this file and `docs/architecture.md`).

## Opening a Change
- Include reproduction steps for fixes and a brief “expected vs actual” summary.
- List which test targets you ran and any that were skipped due to time.
- Mention backward-compatibility or deployment risks (packet format, WAL layout, API surface, key/epoch rotation).
- If your change alters network behavior, note the default fanout or timers you touched so reviewers can reason about blast radius.
