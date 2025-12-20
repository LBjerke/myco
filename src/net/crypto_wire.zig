// AES-GCM helper for Wire messages: derive a shared key from two pubkeys and seal/open payloads.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Key = [32]u8;
pub const Nonce = [12]u8;
pub const Tag = [16]u8;

/// Deterministically derive a shared key from server and client pubkeys.
pub fn deriveKey(server_pub: [32]u8, client_pub: [32]u8) Key {
    var hasher = Sha256.init(.{});
    hasher.update(&server_pub);
    hasher.update(&client_pub);
    return hasher.finalResult();
}

pub fn mixPsk(key: Key, psk: []const u8) Key {
    var out = Sha256.init(.{});
    out.update(&key);
    out.update(psk);
    return out.finalResult();
}

pub fn seal(key: Key, plaintext: []const u8, allocator: std.mem.Allocator) !struct {
    nonce: Nonce,
    tag: Tag,
    ct: []u8,
} {
    var nonce: Nonce = undefined;
    std.crypto.random.bytes(&nonce);

    const ct = try allocator.alloc(u8, plaintext.len);
    errdefer allocator.free(ct);

    var tag: Tag = undefined;
    AesGcm.encrypt(ct, &tag, plaintext, &[_]u8{}, nonce, key);

    return .{ .nonce = nonce, .tag = tag, .ct = ct };
}

pub fn open(key: Key, nonce: Nonce, tag: Tag, ct: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const pt = try allocator.alloc(u8, ct.len);
    errdefer allocator.free(pt);
    try AesGcm.decrypt(pt, ct, tag, &[_]u8{}, nonce, key);
    return pt;
}
