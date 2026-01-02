// Simple tick-based clock used across the simulator for deterministic timing.
// This file implements a simple tick-based `Clock` for the Myco simulator.
// This deterministic clock provides a consistent way to track time within
// simulations, which is essential for ensuring reproducible timing of events
// and interactions between simulated nodes. The `tick()` method advances
// the simulation time by one discrete unit, and `now()` returns the current
// simulation time.
//
pub const Clock = struct {
    tick_count: u64 = 0,

    /// Advance time by one discrete unit.
    pub fn tick(self: *Clock) void {
        self.tick_count += 1;
    }

    /// Current time in simulation ticks.
    pub fn now(self: *Clock) u64 {
        return self.tick_count;
    }
};
