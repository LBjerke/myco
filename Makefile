# Simple helpers to run simulation tests directly (skipping build graph).
# Usage:
#   make sim-50-realworld          # ReleaseFast (default)
#   make sim-50-realworld-debug    # Debug
#   make sim-20-pi-wifi            # ReleaseFast (default)

ZIG ?= zig
ZIG_CACHE ?= ./zig-cache
ZIG_OPTS ?= -OReleaseFast
ZIG_TEST := ZIG_LOCAL_CACHE_DIR=$(ZIG_CACHE) ZIG_GLOBAL_CACHE_DIR=$(ZIG_CACHE) $(ZIG) test $(ZIG_OPTS) --dep myco -Mroot=tests/simulation.zig -Mmyco=src/lib.zig

.PHONY: sim-50-realworld sim-50-realworld-debug sim-20-pi-wifi

sim-50-realworld:
	$(ZIG_TEST) --test-filter "Simulation: 50 nodes (realworld profile)"

sim-50-realworld-debug:
	$(MAKE) ZIG_OPTS=-ODebug sim-50-realworld

sim-20-pi-wifi:
	$(ZIG_TEST) --test-filter "Simulation: 20 nodes (pi-ish wifi profile)"
