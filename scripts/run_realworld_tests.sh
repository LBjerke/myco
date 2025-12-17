#!/usr/bin/env bash
set -euo pipefail

# Real-world-ish test runner for Myco.
# - Builds the ReleaseSmall binary (fits Pi Zero W class targets)
# - Runs the key simulation profiles with ReleaseFast optimizations
# - Uses local cache dirs to avoid permission issues on shared runners

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-./zig-cache}"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-./zig-cache}"
export ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR

echo "==> Building ReleaseSmall binary (compact target build)..."
zig build -Doptimize=ReleaseSmall

echo "==> Running Simulation: 50 nodes (realworld profile) [ReleaseFast] ..."
zig build -Doptimize=ReleaseFast sim-50-realworld

echo "==> Running Simulation: 20 nodes (pi-ish wifi profile) [ReleaseFast] ..."
zig build -Doptimize=ReleaseFast sim-20-pi-wifi

echo "All real-world tests completed."
