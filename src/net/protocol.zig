// Binary-safe protocol helpers for the real network layer: framing, JSON payloads, and handshake.
const std = @import("std");
const Identity = @import("identity.zig").Identity;

/// High-level message types carried over the TCP stream.
pub const MessageType = enum {
    ListServices,
    ServiceList,
    DeployService,
    FetchService,
    ServiceConfig,
    Error,
    UploadStart,
    Gossip,
    GossipDone, // <--- NEW
};

/// Envelope framing a typed payload.
pub const Packet = struct {
    type: MessageType,
    payload: []const u8 = "",
};

pub const Wire = struct {
    /// Serialize and send a typed message with length prefix framing.
    pub fn send(stream: std.net.Stream, allocator: std.mem.Allocator, msg_type: MessageType, data: anytype) !void {
        // FIX 1: Use std.fmt + std.json.fmt to serialize to string first
        const payload_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
        defer allocator.free(payload_str);

        const packet = Packet{ .type = msg_type, .payload = payload_str };
        
        const packet_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(packet, .{})});
        defer allocator.free(packet_json);

        const len = @as(u32, @intCast(packet_json.len));
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, len, .big);
        
        // FIX 2: Use .writer().writeAll()
        try stream.writeAll(&header);
        try stream.writeAll(packet_json);
    }

    /// Receive and deserialize a framed packet.
    pub fn receive(stream: std.net.Stream, allocator: std.mem.Allocator) !Packet {
        var header: [4]u8 = undefined;
        
        // FIX 3: Use .reader().readAll()
        const n = try stream.read(&header);
        if (n == 0) return error.EndOfStream;
        if (n != 4) return error.IncompleteMessage;

        const len = std.mem.readInt(u32, &header, .big);
        if (len > 10 * 1024 * 1024) return error.MessageTooLarge;

        const buffer = try allocator.alloc(u8, len);
        // We pass ownership of buffer to the Packet via dupe, so we defer free here
        defer allocator.free(buffer);

        // FIX 4: Use .reader().readAll()
        if ((try stream.read(buffer)) != len) {
            return error.IncompleteMessage;
        }

        const parsed = try std.json.parseFromSlice(Packet, allocator, buffer, .{ .ignore_unknown_fields = true });
        defer parsed.deinit(); 

        const payload_dupe = try allocator.dupe(u8, parsed.value.payload);
        
        return Packet{ .type = parsed.value.type, .payload = payload_dupe };
    }
       // --- File Streaming (The Missing Functions) ---

    /// Stream a file from Disk -> Network (Zero RAM overhead)
    /// Stream a file from disk to the network without buffering the whole payload.
    pub fn streamSend(stream: std.net.Stream, file: std.fs.File, size: u64) !void {
        var buf: [4096]u8 = undefined;
        var remaining = size;

        while (remaining > 0) {
            const to_read = @min(remaining, buf.len);
            // Use file.read (direct) or file.reader().read()
            const n = try file.read(buf[0..to_read]);
            if (n == 0) return error.UnexpectedEOF;
            
            try stream.writeAll(buf[0..n]);
            remaining -= n;
        }
    }

    /// Stream a file from Network -> Disk
    /// Stream a file from the network into a file on disk.
    pub fn streamReceive(stream: std.net.Stream, file: std.fs.File, size: u64) !void {
        var buf: [4096]u8 = undefined;
        var remaining = size;

        while (remaining > 0) {
            const to_read = @min(remaining, buf.len);
            const n = try stream.read(buf[0..to_read]);
            if (n == 0) return error.UnexpectedEOF;

            _ = try std.posix.write(file.handle, buf[0..n]);
            remaining -= n;
        }
    }
};

/// Mutual-auth handshake between peers using Ed25519 identity.
pub const Handshake = struct {
    /// Server side: issue a challenge and verify the signed response.
    pub fn performServer(stream: std.net.Stream, allocator: std.mem.Allocator) !void {
        var challenge: [32]u8 = undefined;
        std.crypto.random.bytes(&challenge);
        
        // FIX: .writer().writeAll()
        try stream.writeAll(&challenge);

        var response: [96]u8 = undefined;
        
        // FIX: .reader().readAll()
        const n = try stream.read(&response);
        
        if (n == 0) return error.EndOfStream; 
        if (n != 96) return error.InvalidHandshakeLength;

        var signature: [64]u8 = undefined;
        @memcpy(&signature, response[0..64]);
        var pub_key: [32]u8 = undefined;
        @memcpy(&pub_key, response[64..96]);

        if (Identity.verify(pub_key, &challenge, signature)) {
            const hex_id = try Identity.bytesToHex(allocator, &pub_key);
            defer allocator.free(hex_id);
            // Print using {s} to avoid formatter crashes
            std.debug.print("[+] Peer Authenticated! ID: {s}\n", .{hex_id[0..8]});
            
            // FIX: .writer().writeAll()
            try stream.writeAll("OK");
        } else {
            return error.AuthenticationFailed;
        }
    }

    /// Client side: respond to challenge with signature and await OK.
    pub fn performClient(stream: std.net.Stream, ident: *Identity) !void {
        var challenge: [32]u8 = undefined;
        
        // FIX: .reader().readAll()
        if ((try stream.read(&challenge)) != 32) return error.InvalidChallenge;

        const sig = ident.sign(&challenge);
        
        // Buffer the write
        var auth_packet: [96]u8 = undefined;
        @memcpy(auth_packet[0..64], &sig);
        @memcpy(auth_packet[64..96], &ident.keypair.public_key.bytes);
        
        // FIX: .writer().writeAll()
        try stream.writeAll(&auth_packet);

        var result: [2]u8 = undefined;
        const n = try stream.read(&result);
        if (n != 2) return error.HandshakeRejected;
        
        if (!std.mem.eql(u8, &result, "OK")) return error.HandshakeRejected;
    }
};
