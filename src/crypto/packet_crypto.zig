// Packet-level crypto: derive a per-link key from sender pubkey + dest id,
// encrypt payload with a simple XOR stream, and authenticate with a truncated SHA256 tag.
// This file implements packet-level cryptography for secure communication
// between Myco nodes. It provides functionalities to derive per-link encryption
// keys, encrypt and decrypt packet payloads using an XOR stream cipher, and
// authenticate messages with a truncated SHA256 hash. A key cache is
// utilized to enhance performance. This module is fundamental for ensuring
// the confidentiality and integrity of data exchanged over the network.
//
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Packet = @import("../packet.zig").Packet;
const Wyhash = std.hash.Wyhash;

const KeyCacheSize: usize = 1024;
const KeyCacheMask: usize = KeyCacheSize - 1;

comptime {
    if ((KeyCacheSize & KeyCacheMask) != 0) {
        @compileError("KeyCacheSize must be a power of two.");
    }
}

const KeyCacheEntry = struct {
    state: u8 = 0,
    dest_id: u16 = 0,
    pubkey: [32]u8 = [_]u8{0} ** 32,
    key: [32]u8 = [_]u8{0} ** 32,
};

var key_cache: [KeyCacheSize]KeyCacheEntry = [_]KeyCacheEntry{.{}} ** KeyCacheSize;

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

fn keyCacheIndex(sender_pubkey: [32]u8, dest_id: u16) usize {
    var hasher = Wyhash.init(0);
    hasher.update(&sender_pubkey);
    const dest_bytes = [2]u8{
        @as(u8, @truncate(dest_id)),
        @as(u8, @truncate(dest_id >> 8)),
    };
    hasher.update(&dest_bytes);
    return @intCast(hasher.final());
}

fn getKey(sender_pubkey: [32]u8, dest_id: u16) [32]u8 {
    var idx = keyCacheIndex(sender_pubkey, dest_id) & KeyCacheMask;
    var probes: usize = 0;
    while (probes < KeyCacheSize) : (probes += 1) {
        const entry = &key_cache[idx];
        if (entry.state == 0) {
            const derived = deriveKey(sender_pubkey, dest_id);
            entry.state = 1;
            entry.dest_id = dest_id;
            entry.pubkey = sender_pubkey;
            entry.key = derived;
            return derived;
        }
        if (entry.dest_id == dest_id and std.mem.eql(u8, &entry.pubkey, &sender_pubkey)) {
            return entry.key;
        }
        idx = (idx + 1) & KeyCacheMask;
    }
    return deriveKey(sender_pubkey, dest_id);
}

fn xorStream(base: Sha256, nonce: [8]u8, buf: []u8) void {
    var counter: u64 = 0;
    var idx: usize = 0;
    while (idx < buf.len) : (counter += 1) {
        var msg: [16]u8 = undefined;
        @memcpy(msg[0..8], &nonce);
        @memcpy(msg[8..16], std.mem.toBytes(counter)[0..8]);
        var hasher = base;
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

    const key = getKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);

    var base = Sha256.init(.{});
    base.update(&key);
    xorStream(base, pkt.nonce, pkt.payload[0..len]);

    var tag_hasher = base;
    tag_hasher.update(pkt.payload[0..len]);
    const tag_full = tag_hasher.finalResult();
    @memcpy(pkt.auth_tag[0..12], tag_full[0..12]);
}

pub fn open(pkt: *Packet, dest_id: u16) bool {
    const key = getKey(pkt.sender_pubkey, dest_id);
    const len: usize = @min(@as(usize, pkt.payload_len), pkt.payload.len);

    var base = Sha256.init(.{});
    base.update(&key);
    var tag_hasher = base;
    tag_hasher.update(pkt.payload[0..len]);
    const tag_full = tag_hasher.finalResult();
    if (!std.mem.eql(u8, pkt.auth_tag[0..12], tag_full[0..12])) return false;

    xorStream(base, pkt.nonce, pkt.payload[0..len]);
    return true;
}
