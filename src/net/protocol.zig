
const std = @import("std");
// ✅ Import the correct fixed-size Packet
const FixedPacket = @import("../packet.zig").Packet;

// Keep Enums
pub const MessageType = enum {
    ListServices,
    ServiceList,
    DeployService,
    FetchService,
    ServiceConfig,
    Error,
    UploadStart,
    Gossip,
    GossipDone,
};

pub const SecurityMode = enum { plaintext, aes_gcm };

pub const HandshakeOptions = struct {
    allow_plaintext: bool = false,
    force_plaintext: bool = false,
};

pub const HandshakeResult = struct {
    mode: SecurityMode,
    shared_key: [32]u8,
    server_pub: [32]u8,
    client_pub: [32]u8,
};

pub const Wire = struct {
    /// Zero-Alloc Send
    pub fn send(stream: std.net.Stream, packet: *const FixedPacket) !void {
        const bytes = std.mem.asBytes(packet);
        try stream.writeAll(bytes);
    }

    /// Zero-Alloc Receive with explicit loop
    pub fn receive(stream: std.net.Stream, out_packet: *FixedPacket) !void {
        const bytes = std.mem.asBytes(out_packet);
        var index: usize = 0;
        
        // Read exactly 1024 bytes
        while (index < bytes.len) {
            const n = try stream.read(bytes[index..]);
            if (n == 0) return error.EndOfStream;
            index += n;
        }
    }
};

// Handshake logic remains structurally same, just ensure it uses std.net.Stream
pub const Handshake = struct {
    // ... (Keep your Handshake implementation from before) ...
    // If you need the Handshake code again because it was truncated, 
    // simply keep the existing Handshake struct in this file.
    // The critical fix is deleting the old 'Packet' struct and updating Wire.
    
    // Minimal mock for compilation if you lost the body:
    const server_hello_len = 129;
    const client_hello_len = 97;
    
    pub fn performServer(stream: std.net.Stream, allocator: std.mem.Allocator, ident: anytype, opts: HandshakeOptions) !HandshakeResult {
        _ = stream; _ = allocator; _ = ident; _ = opts;
        // This function body should match what you had in the previous 'full' protocol.zig
        // Returning a dummy for build check if needed, but ideally preserve your logic.
        return HandshakeResult{ 
            .mode = .plaintext, .shared_key = undefined, .server_pub = undefined, .client_pub = undefined 
        };
    }

    pub fn performClient(stream: std.net.Stream, allocator: std.mem.Allocator, ident: anytype, opts: HandshakeOptions) !HandshakeResult {
        _ = stream; _ = allocator; _ = ident; _ = opts;
        return HandshakeResult{ 
            .mode = .plaintext, .shared_key = undefined, .server_pub = undefined, .client_pub = undefined 
        };
    }
};
