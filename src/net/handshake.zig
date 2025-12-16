// Identity primitives: deterministic Ed25519 key generation and signing helpers.
const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;

/// The permanent identity of a Node.
/// Size: 32 bytes (Public Key) + 64 bytes (Secret Key) = 96 bytes.
/// Permanent node identity with deterministic key generation.
pub const Identity = struct {
    key_pair: Ed25519.KeyPair,

    /// Generate a deterministic identity from a simulation seed.
    /// This ensures Node 0 always has the same Public Key in every test run.
    pub fn initDeterministic(seed_u64: u64) Identity {
        // Expand u64 into 32 bytes for the Ed25519 seed
        var seed_bytes = [_]u8{0} ** 32;
        std.mem.writeInt(u64, seed_bytes[0..8], seed_u64, .little);
        // Fill the rest to mix entropy slightly (optional, but good for variance)
        std.mem.writeInt(u64, seed_bytes[8..16], ~seed_u64, .little);

        const kp = Ed25519.KeyPair.generateDeterministic(seed_bytes) catch unreachable;
        return .{ .key_pair = kp };
    }

    /// Sign a 1024-byte packet payload.
    /// Returns the 64-byte signature.
    pub fn sign(self: *const Identity, msg: []const u8) [64]u8 {
        const sig_struct = self.key_pair.sign(msg, null) catch unreachable;
        return sig_struct.toBytes();
    }

    /// Verify a signature from another node.
    pub fn verify(public_key_bytes: [32]u8, msg: []const u8, sig: [64]u8) bool {
        const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
        const sigs = std.crypto.sign.Ed25519.Signature.fromBytes(sig);
        sigs.verify(msg,key) catch return false;
        return true;
    }
};
