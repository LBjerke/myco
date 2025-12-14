const std = @import("std");

pub const DeterministicRandom = struct {
    // FIX: std.rand -> std.Random
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) DeterministicRandom {
        return .{
            // FIX: std.rand -> std.Random
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn random(self: *DeterministicRandom) std.Random {
        return self.prng.random();
    }

    pub fn chance(self: *DeterministicRandom, probability: f64) bool {
        return self.random().float(f64) < probability;
    }
};
