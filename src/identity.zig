const std = @import("std");

pub const Identity = struct {
    keypair: std.crypto.sign.Ed25519.KeyPair,
    allocator: std.mem.Allocator,

    // Ed25519 seeds are always 32 bytes.
    const SEED_LEN = 32;

    pub fn init(allocator: std.mem.Allocator) !Identity {
        const dir_path = "/var/lib/myco";

        // Try to create dir, ignore if exists
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                // Ignore permissions for dev envs (will fail to save later, but ephemeral works)
            }
        };

        const key_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "node.key" });
        defer allocator.free(key_path);

        var seed: [SEED_LEN]u8 = undefined;
        var loaded = false;

        // 1. Try to load existing key
        if (std.fs.openFileAbsolute(key_path, .{})) |file| {
            defer file.close();
            const bytes_read = try file.readAll(&seed);
            if (bytes_read == SEED_LEN) {
                loaded = true;
            }
        } else |_| {}

        // 2. Generate New Key if needed
        if (!loaded) {
            std.crypto.random.bytes(&seed);

            if (std.fs.createFileAbsolute(key_path, .{})) |file| {
                defer file.close();
                try file.writeAll(&seed);
            } else |err| {
                if (err == error.AccessDenied) {
                    // Just print to stderr directly to avoid dependency on UX module here
                    std.debug.print("[!] Warning: Cannot write to {s}. Identity will be ephemeral.\n", .{key_path});
                }
            }
        }

        // 3. Derive Keypair
        // FIX: Use fromSeed instead of create
        // FIX: Remove 'try', as derivation is now infallible
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

        return Identity{ .keypair = kp, .allocator = allocator };
    }
    pub fn sign(self: *Identity, message: []const u8) [64]u8 {
        // We assume our keypair is valid, so we catch unreachable
        const sig_struct = self.keypair.sign(message, null) catch unreachable;
        return sig_struct.toBytes();
    }

    /// Static Helper: Convert any bytes to Hex String (Robust vs std.fmt bugs)
    pub fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const hex_chars = "0123456789abcdef";
        var result = try allocator.alloc(u8, bytes.len * 2);
        for (bytes, 0..) |b, i| {
            result[i * 2] = hex_chars[b >> 4];
            result[i * 2 + 1] = hex_chars[b & 0xF];
        }
        return result;
    }

    /// Verify a signature from another node
    /// Returns true if valid
    pub fn verify(public_key_bytes: [32]u8, message: []const u8, signature: [64]u8) bool {
        // Construct a verification key from raw bytes
        const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);

        // Verify
        sig.verify(message, key) catch return false;
        return true;
    }

    pub fn getPublicKeyHex(self: *Identity) ![]u8 {
        const bytes = self.keypair.public_key.bytes;
        const hex_chars = "0123456789abcdef";

        // Allocate exact size (64 chars)
        var result = try self.allocator.alloc(u8, bytes.len * 2);

        for (bytes, 0..) |b, i| {
            result[i * 2] = hex_chars[b >> 4]; // High nibble
            result[i * 2 + 1] = hex_chars[b & 0xF]; // Low nibble
        }

        return result;
    }
};
