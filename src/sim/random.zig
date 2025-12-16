// Deterministic random utilities used by the simulator for reproducible runs.
const std = @import("std");

pub const DeterministicRandom = struct {
    // FIX: std.rand -> std.Random
    prng: std.Random.DefaultPrng,

    /// Initialize the PRNG with a fixed seed.
    pub fn init(seed: u64) DeterministicRandom {
        return .{
            // FIX: std.rand -> std.Random
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Access a std.Random facade for convenience.
    pub fn random(self: *DeterministicRandom) std.Random {
        return self.prng.random();
    }

    /// Probability helper: true with the given probability.
    pub fn chance(self: *DeterministicRandom, probability: f64) bool {
        return self.random().float(f64) < probability;
    }
};
