const std = @import("std");
const Entry = @import("../sync/crdt.zig").Entry;
const PacketPayloadLen = @import("../packet.zig").PayloadLen;
const PacketPayloadAlign = @alignOf(@import("../packet.zig").Packet);
const limits = @import("../core/limits.zig");

pub const PayloadExpandedLen: usize = PacketPayloadLen * 2;
pub const PayloadExpandedAlign = @max(PacketPayloadAlign, @alignOf(u64));
const CompressMaxDistance: usize = 64;
const CompressMaxMatch: usize = 66;

fn varintLen(value: u64) usize {
    var v = value;
    var len: usize = 1;
    while (v >= 0x80) {
        v >>= 7;
        len += 1;
    }
    return len;
}

pub fn writeVarint(value: u64, dest: []u8) usize {
    var v = value;
    var idx: usize = 0;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        dest[idx] = byte;
        idx += 1;
        if (v == 0) break;
    }
    return idx;
}

pub fn readVarint(src: []const u8, cursor: *usize) ?u64 {
    var shift: u6 = 0;
    var value: u64 = 0;
    while (cursor.* < src.len and shift <= 63) {
        const byte = src[cursor.*];
        cursor.* += 1;
        value |= (@as(u64, byte & 0x7f) << shift);
        if ((byte & 0x80) == 0) return value;
        if (shift > 57) return null;
        shift += 7;
    }
    return null;
}

fn zigzagEncodeI64(value: i64) u64 {
    const bits = @as(u64, @bitCast(value));
    const sign = @as(u64, @bitCast(value >> 63));
    return (bits << 1) ^ sign;
}

fn zigzagDecodeU64(value: u64) i64 {
    return @as(i64, @bitCast(value >> 1)) ^ -@as(i64, @intCast(value & 1));
}

pub fn compressPayload(src: []const u8, dest: []u8) ?u16 {
    if (src.len == 0 or src.len > std.math.maxInt(u16)) return null;
    if (dest.len < 2) return null;

    std.mem.writeInt(u16, dest[0..2], @intCast(src.len), .little);
    var out: usize = 2;
    var literal_start: usize = 0;
    var i: usize = 0;

    while (i < src.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        const max_dist: usize = @min(i, CompressMaxDistance);

        if (max_dist > 0) {
            var dist: usize = 1;
            while (dist <= max_dist) : (dist += 1) {
                var match_len: usize = 0;
                while (match_len < CompressMaxMatch and i + match_len < src.len and src[i + match_len] == src[i - dist + match_len]) : (match_len += 1) {}
                if (match_len >= 3 and match_len > best_len) {
                    best_len = match_len;
                    best_dist = dist;
                    if (match_len == CompressMaxMatch) break;
                }
            }
        }

        if (best_len >= 3) {
            var lit_idx: usize = literal_start;
            while (lit_idx < i) {
                const chunk: usize = @min(i - lit_idx, 128);
                if (out + 1 + chunk > dest.len) return null;
                dest[out] = @intCast(chunk - 1);
                out += 1;
                @memcpy(dest[out .. out + chunk], src[lit_idx .. lit_idx + chunk]);
                out += chunk;
                lit_idx += chunk;
            }

            if (out + 2 > dest.len) return null;
            dest[out] = 0x80 | @as(u8, @intCast(best_len - 3));
            dest[out + 1] = @intCast(best_dist);
            out += 2;
            i += best_len;
            literal_start = i;
        } else {
            i += 1;
        }
    }

    if (literal_start < src.len) {
        var lit_idx: usize = literal_start;
        while (lit_idx < src.len) {
            const chunk: usize = @min(src.len - lit_idx, 128);
            if (out + 1 + chunk > dest.len) return null;
            dest[out] = @intCast(chunk - 1);
            out += 1;
            @memcpy(dest[out .. out + chunk], src[lit_idx .. lit_idx + chunk]);
            out += chunk;
            lit_idx += chunk;
        }
    }

    if (out >= src.len) return null;
    return @intCast(out);
}

pub fn decompressPayload(src: []const u8, dest: []u8) ?u16 {
    if (src.len < 2) return null;

    const out_len = std.mem.readInt(u16, src[0..2], .little);
    if (out_len == 0 or out_len > dest.len) return null;

    var out_pos: usize = 0;
    var in_pos: usize = 2;

    while (out_pos < out_len and in_pos < src.len) {
        const control = src[in_pos];
        in_pos += 1;
        if ((control & 0x80) == 0) {
            const run_len: usize = @as(usize, control) + 1;
            if (in_pos + run_len > src.len or out_pos + run_len > out_len) return null;
            @memcpy(dest[out_pos .. out_pos + run_len], src[in_pos .. in_pos + run_len]);
            in_pos += run_len;
            out_pos += run_len;
        } else {
            const run_len: usize = @as(usize, control & 0x7f) + 3;
            if (in_pos >= src.len or out_pos + run_len > out_len) return null;
            const dist = src[in_pos];
            in_pos += 1;
            if (dist == 0 or dist > out_pos) return null;
            var k: usize = 0;
            while (k < run_len) : (k += 1) {
                dest[out_pos + k] = dest[out_pos + k - dist];
            }
            out_pos += run_len;
        }
    }

    if (out_pos != out_len) return null;
    return out_len;
}

/// Encode a digest using LEB128 varints to stuff as many entries as possible into the 952-byte payload.
pub fn encodeDigest(entries: []const Entry, dest: []u8) u16 {
    if (dest.len < 2) return 0;

    var cursor: usize = 2; // reserve space for count
    var written: u16 = 0;

    for (entries) |entry| {
        const needed = varintLen(entry.id) + varintLen(entry.version);
        if (cursor + needed > dest.len) break;
        cursor += writeVarint(entry.id, dest[cursor..]);
        cursor += writeVarint(entry.version, dest[cursor..]);
        written += 1;
    }

    std.mem.writeInt(u16, dest[0..2], written, .little);
    return @intCast(cursor);
}

/// Encode a digest in columnar format (ids, wall deltas, logicals) to maximize payload usage.
pub fn encodeDigestColumnar(entries: []const Entry, dest: []u8) u16 {
    if (dest.len < 2) return 0;

    var total_len: usize = 2;
    var count: usize = 0;
    var prev_wall: i64 = 0;

    for (entries, 0..) |entry, idx| {
        const id_len = varintLen(entry.id);
        const wall: u64 = entry.version >> 16;
        const logical: u64 = entry.version & 0xffff;
        const wall_len = if (idx == 0)
            varintLen(wall)
        else
            varintLen(zigzagEncodeI64(@as(i64, @intCast(wall)) - prev_wall));
        const logical_len = varintLen(logical);
        if (total_len + id_len + wall_len + logical_len > dest.len) break;
        total_len += id_len + wall_len + logical_len;
        count += 1;
        prev_wall = @as(i64, @intCast(wall));
    }

    if (count == 0) return 0;
    std.mem.writeInt(u16, dest[0..2], @intCast(count), .little);

    var cursor: usize = 2;
    for (entries[0..count]) |entry| {
        cursor += writeVarint(entry.id, dest[cursor..]);
    }

    prev_wall = 0;
    for (entries[0..count], 0..) |entry, idx| {
        const wall: u64 = entry.version >> 16;
        if (idx == 0) {
            cursor += writeVarint(wall, dest[cursor..]);
        } else {
            const delta = @as(i64, @intCast(wall)) - prev_wall;
            cursor += writeVarint(zigzagEncodeI64(delta), dest[cursor..]);
        }
        prev_wall = @as(i64, @intCast(wall));
    }

    for (entries[0..count]) |entry| {
        const logical: u64 = entry.version & 0xffff;
        cursor += writeVarint(logical, dest[cursor..]);
    }

    return @intCast(cursor);
}

/// Decode a compressed digest back into Entry structs (up to out.len entries).
pub fn decodeDigest(src: []const u8, out: []Entry) usize {
    if (src.len < 2 or out.len == 0) return 0;

    const target = std.mem.readInt(u16, src[0..2], .little);
    var cursor: usize = 2;
    var idx: usize = 0;

    while (idx < out.len and idx < target) {
        const id = readVarint(src, &cursor) orelse break;
        const version = readVarint(src, &cursor) orelse break;
        out[idx] = .{ .id = id, .version = version };
        idx += 1;
    }

    return idx;
}

/// Decode a columnar digest into Entry structs (up to out.len entries).
pub fn decodeDigestColumnar(src: []const u8, out: []Entry) usize {
    if (src.len < 2 or out.len == 0) return 0;

    const target = std.mem.readInt(u16, src[0..2], .little);
    const count: usize = @min(out.len, @as(usize, target));
    var cursor: usize = 2;

    for (0..count) |i| {
        const id = readVarint(src, &cursor) orelse return 0;
        out[i].id = id;
        out[i].version = 0;
    }

    var prev_wall: i64 = 0;
    for (0..count) |i| {
        const raw = readVarint(src, &cursor) orelse return 0;
        var wall: i64 = undefined;
        if (i == 0) {
            wall = @as(i64, @intCast(raw));
        } else {
            wall = prev_wall + zigzagDecodeU64(raw);
        }
        if (wall < 0) return 0;
        out[i].version = @as(u64, @intCast(wall)) << 16;
        prev_wall = wall;
    }

    for (0..count) |i| {
        const logical = readVarint(src, &cursor) orelse return 0;
        out[i].version |= @min(logical, 0xffff);
    }

    return count;
}

pub const CrdtKind = enum(u8) {
    services_delta = 1,
    services_recent = 2,
    services_sample = 3,
};

pub const SectionMarker: u8 = 0x80;
pub const SectionHeaderLen: usize = 3; // kind + u16 len

fn appendDigestSection(kind: CrdtKind, entries: []const Entry, payload: []u8, cursor: *usize) bool {
    if (entries.len == 0) return false;
    if (cursor.* + SectionHeaderLen + 2 > payload.len) return false;

    const header_pos = cursor.*;
    const data_start = header_pos + SectionHeaderLen;
    const used = encodeDigest(entries, payload[data_start..]);
    if (used == 0 or data_start + used > payload.len) return false;
    const count = std.mem.readInt(u16, @ptrCast(payload[data_start .. data_start + 2].ptr), .little);
    if (count == 0) return false;

    payload[header_pos] = SectionMarker | @intFromEnum(kind);
    std.mem.writeInt(u16, @ptrCast(payload[header_pos + 1 .. header_pos + 3].ptr), used, .little);
    cursor.* = data_start + used;
    return true;
}

fn appendDigestSectionColumnar(kind: CrdtKind, entries: []const Entry, payload: []u8, cursor: *usize) bool {
    if (entries.len == 0) return false;
    if (cursor.* + SectionHeaderLen + 2 > payload.len) return false;

    const header_pos = cursor.*;
    const data_start = header_pos + SectionHeaderLen;
    const used = encodeDigestColumnar(entries, payload[data_start..]);
    if (used == 0 or data_start + used > payload.len) return false;
    const count = std.mem.readInt(u16, @ptrCast(payload[data_start .. data_start + 2].ptr), .little);
    if (count == 0) return false;

    payload[header_pos] = SectionMarker | @intFromEnum(kind);
    std.mem.writeInt(u16, @ptrCast(payload[header_pos + 1 .. header_pos + 3].ptr), used, .little);
    cursor.* = data_start + used;
    return true;
}

pub fn encodeSyncPayload(payload: []u8, delta_entries: []const Entry, sample_entries: []const Entry) usize {
    var cursor: usize = 0;
    if (delta_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_delta, delta_entries, payload, &cursor);
    }
    if (cursor < payload.len and sample_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_sample, sample_entries, payload, &cursor);
    }
    return cursor;
}

pub fn encodeControlPayload(payload: []u8, recent_entries: []const Entry, sample_entries: []const Entry) usize {
    var cursor: usize = 0;
    if (recent_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_recent, recent_entries, payload, &cursor);
    }
    if (cursor < payload.len and sample_entries.len > 0) {
        _ = appendDigestSectionColumnar(.services_sample, sample_entries, payload, &cursor);
    }
    return cursor;
}

test "digest compression round-trips and beats fixed-width size" {
    var payload: [952]u8 = undefined;
    var entries: [64]Entry = undefined;

    for (entries, 0..) |_, idx| {
        entries[idx] = .{ .id = idx + 1, .version = (idx + 1) * 3 };
    }

    const used_bytes: u16 = encodeDigest(entries[0..], payload[0..]);
    const encoded_len: usize = @intCast(used_bytes);

    var decoded: [64]Entry = undefined;
    const decoded_len = decodeDigest(payload[0..encoded_len], decoded[0..]);

    try std.testing.expectEqual(entries.len, decoded_len);
    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }

    try std.testing.expect(encoded_len < entries.len * @sizeOf(Entry));
}

test "columnar digest round-trips" {
    var payload: [952]u8 = undefined;
    var entries: [64]Entry = undefined;

    const base_wall: u64 = 1_700_000_000_000;
    for (entries, 0..) |_, idx| {
        const wall = base_wall + @as(u64, idx);
        const logical: u16 = @intCast(idx % 7);
        entries[idx] = .{ .id = idx + 1, .version = (wall << 16) | logical };
    }

    const col_bytes: u16 = encodeDigestColumnar(entries[0..], payload[0..]);
    const col_len: usize = @intCast(col_bytes);

    var decoded: [64]Entry = undefined;
    const decoded_len = decodeDigestColumnar(payload[0..col_len], decoded[0..]);

    try std.testing.expectEqual(entries.len, decoded_len);
    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }
}
