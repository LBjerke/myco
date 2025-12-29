// Runtime identity management: load/generate Ed25519 keys and provide signing helpers.
const std = @import("std");
const limits = @import("../core/limits.zig");

pub const Identity = struct {
    keypair: std.crypto.sign.Ed25519.KeyPair,

    // Ed25519 seeds are always 32 bytes.
    const SEED_LEN = 32;

    /// Load or generate a persistent Ed25519 identity in the state directory.
    pub fn init() !Identity {
        const env_dir = std.posix.getenv("MYCO_STATE_DIR");
        const dir_path = if (env_dir) |d| d[0..d.len] else "/var/lib/myco";

        // Try to create dir, ignore if exists
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                // Ignore permissions for dev envs (will fail to save later, but ephemeral works)
            }
        };

        var key_path_buf: [limits.PATH_MAX]u8 = undefined;
        const key_path = try std.fmt.bufPrint(&key_path_buf, "{s}/node.key", .{dir_path});

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

        return Identity{ .keypair = kp };
    }
    /// Sign a message with the node's secret key.
    pub fn sign(self: *const Identity, message: []const u8) [64]u8 {
        // We assume our keypair is valid, so we catch unreachable
        const sig_struct = self.keypair.sign(message, null) catch unreachable;
        return sig_struct.toBytes();
    }

    /// Static Helper: Convert any bytes to Hex String (Robust vs std.fmt bugs)
    pub fn bytesToHexBuf(dest: []u8, bytes: []const u8) ![]const u8 {
        const hex_chars = "0123456789abcdef";
        if (dest.len < bytes.len * 2) return error.BufferTooSmall;
        for (bytes, 0..) |b, i| {
            dest[i * 2] = hex_chars[b >> 4];
            dest[i * 2 + 1] = hex_chars[b & 0xF];
        }
        return dest[0 .. bytes.len * 2];
    }

    /// Verify a signature from another node.
    pub fn verify(public_key_bytes: [32]u8, message: []const u8, signature: [64]u8) bool {
        // Construct a verification key from raw bytes
        const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);

        // Verify
        sig.verify(message, key) catch return false;
        return true;
    }

    /// Render the public key as a lowercase hex string.
    pub fn getPublicKeyHexBuf(self: *const Identity, out: []u8) ![]const u8 {
        const bytes = self.keypair.public_key.bytes;
        return bytesToHexBuf(out, &bytes);
    }
};

test "Identity: Sign and Verify" {
    // 1. Create Identity (Ephemeral for test)
    // We mock the filesystem path by letting init fail to find a file,
    // or we can just manually create the struct for testing logic.
    // However, init tries to write to /var/lib/myco which will fail in test env.
    // Let's manually init the struct to test the logic methods.

    var seed: [32]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    var ident = Identity{ .keypair = kp };

    // 2. Test Hex Conversion
    var hex_buf: [64]u8 = undefined;
    const hex = try ident.getPublicKeyHexBuf(&hex_buf);
    try std.testing.expectEqual(64, hex.len);

    // 3. Test Signing
    const msg = "Hello Myco";
    const sig = ident.sign(msg);

    // 4. Test Verification (Good)
    const valid = Identity.verify(ident.keypair.public_key.bytes, msg, sig);
    try std.testing.expect(valid);

    // 5. Test Verification (Bad Message)
    const invalid = Identity.verify(ident.keypair.public_key.bytes, "Evil Myco", sig);
    try std.testing.expect(!invalid);
}
