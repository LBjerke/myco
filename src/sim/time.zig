// Simple tick-based clock used across the simulator for deterministic timing.
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
