// Packet-level crypto: derive a per-link key from sender pubkey + dest id,
// encrypt payload with a simple XOR stream, and authenticate with a truncated SHA256 tag.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Packet = @import("../packet.zig").Packet;

fn deriveKey(sender_pubkey: [32]u8, dest_id: u16) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(&sender_pubkey);
    const dest_bytes = [2]u8{
        @as(u8, @truncate(dest_id)),
        @as(u8, @truncate(dest_id >> 8)),
    };
    hasher.update(&dest_bytes);
    return hasher.finalResult();
}

fn xorStream(key: [32]u8, nonce: [8]u8, buf: []u8) void {
    var counter: u64 = 0;
    var idx: usize = 0;
    while (idx < buf.len) : (counter += 1) {
        var msg: [16]u8 = undefined;
        @memcpy(msg[0..8], &nonce);
        @memcpy(msg[8..16], std.mem.toBytes(counter)[0..8]);
        var hasher = Sha256.init(.{});
        hasher.update(&key);
        hasher.update(&msg);
        const block = hasher.finalResult();
        const take = @min(block.len, buf.len - idx);
        for (0..take) |i| {
            buf[idx + i] ^= block[i];
        }
        idx += take;
    }
}

pub fn seal(pkt: *Packet, dest_id: u16) void {
    var nonce: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    pkt.nonce = nonce;

    const key = deriveKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);
    xorStream(key, pkt.nonce, pkt.payload[0..len]);

    var hasher = Sha256.init(.{});
    hasher.update(&key);
    hasher.update(pkt.payload[0..len]);
    const tag_full = hasher.finalResult();
    @memcpy(pkt.auth_tag[0..12], tag_full[0..12]);
}

pub fn open(pkt: *Packet, dest_id: u16) bool {
    const key = deriveKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);

    var hasher = Sha256.init(.{});
    hasher.update(&key);
    hasher.update(pkt.payload[0..len]);
    const tag_full = hasher.finalResult();
    if (!std.mem.eql(u8, pkt.auth_tag[0..12], tag_full[0..12])) return false;

    xorStream(key, pkt.nonce, pkt.payload[0..len]);
    return true;
}
