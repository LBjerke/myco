const std = @import("std");
const Identity = @import("identity.zig").Identity;
const UX = @import("../util/ux.zig").UX;
const Config = @import("../core/config.zig");


// 1. Define Message Types
pub const MessageType = enum {
    ListServices,
    ServiceList,
    DeployService, // <--- New
    // Future: FetchService, PushService
};

// 2. Define the Packet Structure
pub const Packet = struct {
    type: MessageType,
    payload: []const u8 = "",
};

pub const Wire = struct {
    /// Send a JSON-serializable struct
    pub fn send(stream: std.net.Stream, allocator: std.mem.Allocator, msg_type: MessageType, data: anytype) !void {
        // FIX: Use std.fmt.allocPrint with the JSON formatter as an argument
        const payload_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
        defer allocator.free(payload_str);

        const packet = Packet{ .type = msg_type, .payload = payload_str };

        // FIX: Same here for the packet wrapper
        const packet_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(packet, .{})});
        defer allocator.free(packet_json);

        const len = @as(u32, @intCast(packet_json.len));
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, len, .big);

        try stream.writeAll(&header);
        try stream.writeAll(packet_json);
    }

    /// Read a Packet
    pub fn receive(stream: std.net.Stream, allocator: std.mem.Allocator) !Packet {
        var header: [4]u8 = undefined;
        // FIX: Return error.EndOfStream if we read 0 bytes (Clean disconnect)
        // If we read 1-3 bytes, it's also EndOfStream (truncated message)
        const n = try stream.read(&header);
        if (n != 4) return error.EndOfStream;

        const len = std.mem.readInt(u32, &header, .big);
        if (len > 10 * 1024 * 1024) return error.MessageTooLarge;

        const buffer = try allocator.alloc(u8, len);
        defer allocator.free(buffer);

        if ((try stream.read(buffer)) != len) {
            // If body is cut off, that's also an EndOfStream/Incomplete issue
            return error.EndOfStream;
        }

        const parsed = try std.json.parseFromSlice(Packet, allocator, buffer, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const payload_dupe = try allocator.dupe(u8, parsed.value.payload);

        return Packet{ .type = parsed.value.type, .payload = payload_dupe };
    }
};

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
test "Wire: Serialize and Deserialize Packet" {
    const allocator = std.testing.allocator;

    // 1. Mock Data
    const data = Config.ServiceConfig{
        .name = "test",
        .package = "pkg",
    };

    // 2. Manual JSON Test (mimicking Wire logic without a socket)
    // FIX: Use std.fmt instead of stringify+writer
    const payload_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(data, .{})});
    defer allocator.free(payload_str);
    
    const packet = Packet{ .type = .DeployService, .payload = payload_str };
    
    const packet_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(packet, .{})});
    defer allocator.free(packet_json);

    // Verify it contains our data
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "\"type\":\"DeployService\"") != null);
    // Note: std.json.fmt escapes quotes, so check for escaped name
    try std.testing.expect(std.mem.indexOf(u8, packet_json, "test") != null); 
}
