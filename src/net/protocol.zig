// Binary-safe protocol helpers for the real network layer: framing, JSON payloads, and handshake.
const std = @import("std");
const Identity = @import("handshake.zig").Identity;
const CryptoWire = @import("crypto_wire.zig");

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

/// Encrypted envelope (AES-GCM).
pub const SecurePacket = struct {
    type: MessageType,
    nonce: [12]u8,
    tag: [16]u8,
    payload: []const u8 = "",
};

/// Selected transport security for a connection.
pub const SecurityMode = enum { plaintext, aes_gcm };

/// Handshake policy knobs for callers.
pub const HandshakeOptions = struct {
    allow_plaintext: bool = false,
    force_plaintext: bool = false,
};

pub const HandshakeResult = struct {
    mode: SecurityMode,
    shared_key: CryptoWire.Key,
    server_pub: [32]u8,
    client_pub: [32]u8,
};

pub const Wire = struct {
    /// Serialize and send a typed message with length prefix framing (plaintext).
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

    /// Receive and deserialize a framed packet (plaintext).
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

    /// Encrypt + send a message with AES-GCM.
    pub fn sendEncrypted(stream: std.net.Stream, allocator: std.mem.Allocator, key: [32]u8, msg_type: MessageType, data: anytype) !void {
        const payload_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
        defer allocator.free(payload_str);

        const sealed = try @import("crypto_wire.zig").seal(key, payload_str, allocator);
        defer allocator.free(sealed.ct);

        const packet = SecurePacket{ .type = msg_type, .nonce = sealed.nonce, .tag = sealed.tag, .payload = sealed.ct };
        const packet_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(packet, .{})});
        defer allocator.free(packet_json);

        const len = @as(u32, @intCast(packet_json.len));
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, len, .big);
        try stream.writeAll(&header);
        try stream.writeAll(packet_json);
    }

    /// Receive + decrypt a message with AES-GCM.
    pub fn receiveEncrypted(stream: std.net.Stream, allocator: std.mem.Allocator, key: [32]u8) !Packet {
        var header: [4]u8 = undefined;
        const n = try stream.read(&header);
        if (n == 0) return error.EndOfStream;
        if (n != 4) return error.IncompleteMessage;

        const len = std.mem.readInt(u32, &header, .big);
        if (len > 10 * 1024 * 1024) return error.MessageTooLarge;

        const buffer = try allocator.alloc(u8, len);
        defer allocator.free(buffer);

        if ((try stream.read(buffer)) != len) {
            return error.IncompleteMessage;
        }

        const parsed = try std.json.parseFromSlice(SecurePacket, allocator, buffer, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const ct_dupe = try allocator.dupe(u8, parsed.value.payload);
        errdefer allocator.free(ct_dupe);

        const pt = try @import("crypto_wire.zig").open(key, parsed.value.nonce, parsed.value.tag, ct_dupe, allocator);
        errdefer allocator.free(pt);

        const payload_dupe = try allocator.dupe(u8, pt);
        allocator.free(pt);
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
    const server_hello_len = 129;
    const client_hello_len = 97;

    fn modeByte(mode: SecurityMode) u8 {
        return switch (mode) {
            .plaintext => 0,
            .aes_gcm => 1,
        };
    }

    fn decodeMode(value: u8) !SecurityMode {
        return switch (value) {
            0 => .plaintext,
            1 => .aes_gcm,
            else => error.InvalidHandshakeMode,
        };
    }

    fn readExact(stream: std.net.Stream, buf: []u8) !void {
        var read_total: usize = 0;
        while (read_total < buf.len) {
            const n = try stream.read(buf[read_total..]);
            if (n == 0) return error.EndOfStream;
            read_total += n;
        }
    }

    fn negotiate(server_mode: SecurityMode, client_mode: SecurityMode, opts: HandshakeOptions) !SecurityMode {
        if (server_mode == .aes_gcm and client_mode == .aes_gcm) return .aes_gcm;
        if (opts.allow_plaintext or opts.force_plaintext) return .plaintext;
        return error.EncryptionRequired;
    }

    fn modeName(mode: SecurityMode) []const u8 {
        return switch (mode) {
            .plaintext => "plaintext",
            .aes_gcm => "aes-gcm",
        };
    }

    /// Server side: issue a challenge, prove server identity, and derive a shared key.
    pub fn performServer(stream: std.net.Stream, allocator: std.mem.Allocator, ident: *Identity, opts: HandshakeOptions) !HandshakeResult {
        _ = allocator;
        const server_mode: SecurityMode = if (opts.force_plaintext) .plaintext else .aes_gcm;

        var challenge: [32]u8 = undefined;
        std.crypto.random.bytes(&challenge);

        var signed_msg: [33]u8 = undefined;
        @memcpy(signed_msg[0..32], &challenge);
        signed_msg[32] = modeByte(server_mode);
        const server_sig = ident.sign(&signed_msg);

        var hello: [server_hello_len]u8 = undefined;
        @memcpy(hello[0..32], &challenge);
        @memcpy(hello[32..64], &ident.key_pair.public_key.bytes);
        @memcpy(hello[64..128], &server_sig);
        hello[128] = signed_msg[32];

        try stream.writeAll(&hello);

        var response: [client_hello_len]u8 = undefined;
        try readExact(stream, &response);

        var client_sig: [64]u8 = undefined;
        @memcpy(&client_sig, response[0..64]);
        var client_pub: [32]u8 = undefined;
        @memcpy(&client_pub, response[64..96]);
        const client_mode = try decodeMode(response[96]);

        var verify_buf: [34]u8 = undefined;
        @memcpy(verify_buf[0..32], &challenge);
        verify_buf[32] = hello[128];
        verify_buf[33] = response[96];

        if (!Identity.verify(client_pub, &verify_buf, client_sig)) {
            return error.AuthenticationFailed;
        }

        const negotiated_mode = try negotiate(server_mode, client_mode, opts);
        const shared = CryptoWire.deriveKey(ident.key_pair.public_key.bytes, client_pub);

        try stream.writeAll("OK");

        return HandshakeResult{
            .mode = negotiated_mode,
            .shared_key = shared,
            .server_pub = ident.key_pair.public_key.bytes,
            .client_pub = client_pub,
        };
    }

    /// Client side: verify server proof, respond with pubkey, and derive shared key.
    pub fn performClient(stream: std.net.Stream, _allocator: std.mem.Allocator, ident: *Identity, opts: HandshakeOptions) !HandshakeResult {
        _ = _allocator; // currently unused on client side

        var hello: [server_hello_len]u8 = undefined;
        try readExact(stream, &hello);

        var challenge: [32]u8 = undefined;
        @memcpy(&challenge, hello[0..32]);

        var server_pub: [32]u8 = undefined;
        @memcpy(&server_pub, hello[32..64]);

        var server_sig: [64]u8 = undefined;
        @memcpy(&server_sig, hello[64..128]);

        const server_mode = try decodeMode(hello[128]);

        var server_verify: [33]u8 = undefined;
        @memcpy(server_verify[0..32], &challenge);
        server_verify[32] = hello[128];

        if (!Identity.verify(server_pub, &server_verify, server_sig)) {
            return error.AuthenticationFailed;
        }

        const client_mode: SecurityMode = if (opts.force_plaintext) .plaintext else .aes_gcm;
        const negotiated_mode = try negotiate(server_mode, client_mode, opts);

        var client_sig_buf: [34]u8 = undefined;
        @memcpy(client_sig_buf[0..32], &challenge);
        client_sig_buf[32] = hello[128];
        client_sig_buf[33] = modeByte(client_mode);
        const sig = ident.sign(&client_sig_buf);

        var response: [client_hello_len]u8 = undefined;
        @memcpy(response[0..64], &sig);
        @memcpy(response[64..96], &ident.key_pair.public_key.bytes);
        response[96] = modeByte(client_mode);

        try stream.writeAll(&response);

        var result: [2]u8 = undefined;
        try readExact(stream, &result);
        if (!std.mem.eql(u8, &result, "OK")) return error.HandshakeRejected;

        const shared = CryptoWire.deriveKey(server_pub, ident.key_pair.public_key.bytes);

        return HandshakeResult{
            .mode = negotiated_mode,
            .shared_key = shared,
            .server_pub = server_pub,
            .client_pub = ident.key_pair.public_key.bytes,
        };
    }
};
