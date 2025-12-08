const std = @import("std");
const Identity = @import("identity.zig").Identity;
const UX = @import("ux.zig").UX;

pub const Handshake = struct {
    
    /// Server Side: Generate Challenge, Send it, Wait for Sig
    pub fn performServer(stream: std.net.Stream, allocator: std.mem.Allocator) !void {
        // 1. Generate Challenge (32 random bytes)
        var challenge: [32]u8 = undefined;
        std.crypto.random.bytes(&challenge);
        
    var ux = UX.init(allocator);
    defer ux.deinit();

        // 2. Send Challenge
        try stream.writeAll(&challenge);

        // 3. Read Response (Signature + PublicKey)
        // Sig (64) + PubKey (32) = 96 bytes
        var response: [96]u8 = undefined;
        const bytes_read = try stream.read(&response);
        
        if (bytes_read != 96) return error.InvalidHandshakeLength;

        const signature = response[0..64];
        const pub_key = response[64..96];

        // 4. Verify
        if (Identity.verify(pub_key.*, &challenge, signature.*)) {
              // FIX: Use manual hex conversion
            const hex_id = try Identity.bytesToHex(allocator, pub_key);
            defer allocator.free(hex_id);
            ux.success("Peer Authenticated! ID: {s}", .{hex_id});
            
            // Send "OK" back
            try stream.writeAll("OK");
        } else {
            ux.fail("Auth Failed: Bad Signature", .{});
            return error.AuthenticationFailed;
        }
    }

    /// Client Side: Receive Challenge, Sign it, Send Creds
    pub fn performClient(stream: std.net.Stream, ident: *Identity) !void {
        // 1. Read Challenge
        var challenge: [32]u8 = undefined;
        const bytes_read = try stream.read(&challenge);
        if (bytes_read != 32) return error.InvalidChallenge;

        // 2. Sign Challenge
        const sig = ident.sign(&challenge);

        // 3. Send [Sig][PubKey]
        try stream.writeAll(&sig);
        try stream.writeAll(&ident.keypair.public_key.bytes);

        // 4. Wait for OK
        var result: [2]u8 = undefined;
        _ = try stream.read(&result);
        
        if (!std.mem.eql(u8, &result, "OK")) {
            return error.HandshakeRejected;
        }
    }
};
