const std = @import("std");
const Packet = @import("../packet.zig").Packet;
const PacketPayloadLen = @import("../packet.zig").PayloadLen;
const SecretBox = std.crypto.nacl.SecretBox;
const X25519 = std.crypto.dh.X25519;
const Curve25519 = std.crypto.ecc.Curve25519;
const Sha512 = std.crypto.hash.sha2.Sha512;

// Convert Ed25519 Seed to X25519 Secret Key
fn convertSecretKey(seed: [32]u8) [32]u8 {
    var h: [64]u8 = undefined;
    Sha512.hash(&seed, &h, .{});
    var sk = h[0..32].*;
    sk[0] &= 248;
    sk[31] &= 127;
    sk[31] |= 64;
    return sk;
}

// Convert Ed25519 Public Key to X25519 Public Key
// u = (1 + y) / (1 - y)
fn convertPublicKey(ed_pk: [32]u8) ![32]u8 {
    const Fe = Curve25519.Fe;

    var y_bytes = ed_pk;
    y_bytes[31] &= 0x7F; // clear sign bit

    const y = Fe.fromBytes(y_bytes);
    const one = Fe.one;

    // u = (1 + y) / (1 - y)
    const num = one.add(y);
    const den = one.sub(y);

    const u = num.mul(den.invert());

    return u.toBytes();
}

pub fn seal(pkt: *Packet, my_seed: [32]u8, peer_pub_ed: [32]u8) !void {
    // 1. Derive Shared Key
    const my_sk_x = convertSecretKey(my_seed);
    const peer_pk_x = try convertPublicKey(peer_pub_ed);
    const shared_key = try X25519.scalarmult(my_sk_x, peer_pk_x);

    // 2. Generate Nonce
    std.crypto.random.bytes(&pkt.nonce);

    // 3. Encrypt
    const len = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const plaintext = pkt.payload[0..len];

    // We use a temporary buffer to hold (Tag || Ciphertext)
    var cipher_buf: [PacketPayloadLen + SecretBox.tag_length]u8 = undefined;

    SecretBox.seal(cipher_buf[0 .. len + SecretBox.tag_length], plaintext, pkt.nonce, shared_key);

    // 4. Split Tag and Ciphertext
    // Zig's SecretBox puts Tag in first 16 bytes, Ciphertext after.
    @memcpy(&pkt.auth_tag, cipher_buf[0..16]);
    @memcpy(pkt.payload[0..len], cipher_buf[16 .. 16 + len]);
}

pub fn open(pkt: *Packet, my_seed: [32]u8) !bool {
    // 1. Derive Shared Key
    const my_sk_x = convertSecretKey(my_seed);
    const peer_pk_x = try convertPublicKey(pkt.sender_pubkey);
    const shared_key = try X25519.scalarmult(my_sk_x, peer_pk_x);

    const len = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    const ciphertext = pkt.payload[0..len];

    // 2. Reconstruct buffer for open (Tag || Ciphertext)
    var cipher_buf: [PacketPayloadLen + SecretBox.tag_length]u8 = undefined;
    @memcpy(cipher_buf[0..16], &pkt.auth_tag);
    @memcpy(cipher_buf[16 .. 16 + len], ciphertext);

    // 3. Decrypt
    SecretBox.open(pkt.payload[0..len], cipher_buf[0 .. 16 + len], pkt.nonce, shared_key) catch return false;

    return true;
}

test "Roundtrip" {
    var seed_a: [32]u8 = undefined;
    std.crypto.random.bytes(&seed_a);
    const kp_a = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_a);

    var seed_b: [32]u8 = undefined;
    std.crypto.random.bytes(&seed_b);
    const kp_b = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_b);

    var pkt = Packet{};
    pkt.sender_pubkey = kp_a.public_key.bytes;
    pkt.setPayload(123456789);
    const payload_str = "Hello Secure World!";
    @memcpy(pkt.payload[8 .. 8 + payload_str.len], payload_str);
    pkt.payload_len = 8 + @as(u16, @intCast(payload_str.len));

    const original_len = pkt.payload_len;
    const original_payload = pkt.payload;

    // Seal A -> B
    try seal(&pkt, seed_a, kp_b.public_key.bytes);

    // Check that payload changed (encrypted)
    const is_same = std.mem.eql(u8, pkt.payload[0..original_len], original_payload[0..original_len]);
    try std.testing.expect(!is_same);

    // Open at B
    const valid = try open(&pkt, seed_b);
    try std.testing.expect(valid);

    // Check payload restored
    try std.testing.expectEqualSlices(u8, pkt.payload[0..original_len], original_payload[0..original_len]);
    try std.testing.expectEqual(pkt.getPayload(), 123456789);
}
