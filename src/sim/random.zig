// Deterministic random utilities used by the simulator for reproducible runs.
// This file provides the `DeterministicRandom` struct, which is used to
// generate reproducible random numbers within the Myco simulator.
// By initializing with a fixed seed, this module ensures that simulations
// behave consistently across multiple runs, a critical feature for debugging
// and validating distributed algorithms. It wraps `std.Random.DefaultPrng`
// and includes a convenience function for probability-based checks.
//
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
