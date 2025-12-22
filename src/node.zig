// Core node implementation: owns identity, service CRDT, WAL, and gossip behavior.
// Each node is a deterministic replica used by both the real system and the simulator.
const std = @import("std");
const build = @import("std").build;

const crypto_enabled = false;

const Packet = @import("packet.zig").Packet;
const Headers = @import("packet.zig").Headers;
const Identity = @import("net/handshake.zig").Identity;
const WAL = @import("db/wal.zig").WriteAheadLog;
const Service = @import("schema/service.zig").Service;
const ServiceStore = @import("sync/crdt.zig").ServiceStore;
const Entry = @import("sync/crdt.zig").Entry;
const Hlc = @import("sync/hlc.zig").Hlc;

/// Compile-time limits used by the zero-alloc path. Wiring is added in later steps.
pub const ZeroAllocCaps = struct {
    pub const max_services: usize = 512;
    pub const max_peers: usize = 256;
    pub const max_outbox: usize = 1024;
    pub const max_missing: usize = 512;
    pub const wal_bytes: usize = 32 * 1024;
};

/// Toggle zero-alloc mode; defaults on to exercise fixed-capacity structures.
pub const use_zero_alloc = true;

/// Fixed-capacity service map used when zero-alloc mode is on.
pub fn FixedServiceData(comptime max_items: usize) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            id: u64 = 0,
            service: Service = undefined,
        };

        slots: [max_items]Slot = [_]Slot{.{}} ** max_items,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        fn findIndex(self: *const Self, id: u64) ?usize {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.slots[i].id == id) return i;
            }
            return null;
        }

        pub fn put(self: *Self, id: u64, service: Service) !void {
            if (self.findIndex(id)) |idx| {
                self.slots[idx].service = service;
                return;
            }
            if (self.len == max_items) return error.TableFull;
            self.slots[self.len] = .{ .id = id, .service = service };
            self.len += 1;
        }

        pub fn get(self: *const Self, id: u64) ?Service {
            if (self.findIndex(id)) |idx| {
                return self.slots[idx].service;
            }
            return null;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub const Iterator = struct {
            data: *const Self,
            idx: usize = 0,

            pub fn next(self: *Iterator) ?struct { key_ptr: *const u64, value_ptr: *const Service } {
                while (self.idx < self.data.len) : (self.idx += 1) {
                    const slot = &self.data.slots[self.idx];
                    if (slot.id == 0) continue;
                    const key_ptr: *const u64 = &slot.id;
                    const value_ptr: *const Service = &slot.service;
                    self.idx += 1;
                    return .{ .key_ptr = key_ptr, .value_ptr = value_ptr };
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .data = self };
        }
    };
}

const ServiceData = if (use_zero_alloc) FixedServiceData(ZeroAllocCaps.max_services) else std.AutoHashMap(u64, Service);
const Store = if (use_zero_alloc) @import("sync/crdt.zig").FixedServiceStore(ZeroAllocCaps.max_services) else ServiceStore;
pub const OutboxList = if (use_zero_alloc) FixedOutboundList else std.ArrayList(OutboundPacket);
const StoreIterator = if (use_zero_alloc) @import("sync/crdt.zig").FixedServiceStore(ZeroAllocCaps.max_services).Iterator else std.AutoHashMap(u64, u64).Iterator;

const digest_flag_delta_ids: u16 = 0x1;
const digest_flag_compact_hlc: u16 = 0x2;
const digest_flag_shift: u4 = 12;
const digest_count_mask: u16 = 0x0fff;

fn varintLen(value: u64) usize {
    var v = value;
    var len: usize = 1;
    while (v >= 0x80) {
        v >>= 7;
        len += 1;
    }
    return len;
}

fn logDigestEntries(label: []const u8, entries: []const Entry) void {
    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") == null) return;
    std.debug.print("[gossip] {s} entries={d}\n", .{ label, entries.len });
    const max_entries = @min(entries.len, 8);
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        std.debug.print("  [{d}] id={d} ver={d}\n", .{ i, entries[i].id, entries[i].version });
    }
    if (entries.len > max_entries) {
        std.debug.print("  ...\n", .{});
    }
}

fn dumpBuffer(label: []const u8, entries: []const Entry) void {
    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") == null) return;
    std.debug.print("[gossip] dump {s} len={d}\n", .{ label, entries.len });
    const max_entries = @min(entries.len, 8);
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        std.debug.print("  [{d}] id={d} ver={d}\n", .{ i, entries[i].id, entries[i].version });
    }
    if (entries.len > max_entries) {
        std.debug.print("  ...\n", .{});
    }
}

fn logSend(label: []const u8, entries: []const Entry, recipient: ?[32]u8) void {
    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") == null) return;
    if (recipient) |pk| {
        const dest: u32 = std.mem.readInt(u32, pk[0..4], .big);
        std.debug.print("[gossip] send {s} entries={d} dest={x}\n", .{ label, entries.len, dest });
    } else {
        std.debug.print("[gossip] send {s} entries={d} dest=broadcast\n", .{ label, entries.len });
    }
    logDigestEntries(label, entries);
}

fn writeVarint(value: u64, dest: []u8) usize {
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

fn readVarint(src: []const u8, cursor: *usize) ?u64 {
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

/// Encode a digest using delta-coded IDs and compact HLC payloads.
pub fn encodeDigest(entries: []Entry, dest: []u8) u16 {
    if (dest.len < 2) return 0;

    // Sort by id to maximize delta compression.
    std.sort.block(Entry, entries, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.lessThan);

    var cursor: usize = 2; // reserve space for header (flags|count)
    const flags: u16 = digest_flag_delta_ids | digest_flag_compact_hlc;

    var base_wall: u64 = 0;
    if (entries.len > 0) {
        base_wall = Hlc.unpack(entries[0].version).wall;
        for (entries[1..]) |e| {
            const wall = Hlc.unpack(e.version).wall;
            if (wall < base_wall) base_wall = wall;
        }
        const needed = varintLen(base_wall);
        if (cursor + needed > dest.len) return 0;
        cursor += writeVarint(base_wall, dest[cursor..]);
    }

    var prev_id: u64 = 0;
    var written: u16 = 0;

    for (entries) |entry| {
        const hlc = Hlc.unpack(entry.version);
        const id_delta: u64 = if (entry.id >= prev_id) entry.id - prev_id else entry.id;
        const wall_delta: u64 = if (hlc.wall >= base_wall) hlc.wall - base_wall else hlc.wall;

        const needed = varintLen(id_delta) + varintLen(wall_delta) + varintLen(hlc.logical);
        if (cursor + needed > dest.len) break;

        cursor += writeVarint(id_delta, dest[cursor..]);
        cursor += writeVarint(wall_delta, dest[cursor..]);
        cursor += writeVarint(hlc.logical, dest[cursor..]);

        prev_id = entry.id;
        written += 1;
    }

    const capped_count: u16 = @min(written, digest_count_mask);
    const header: u16 = (flags << digest_flag_shift) | capped_count;
    std.mem.writeInt(u16, dest[0..2], header, .little);
    return @intCast(cursor);
}

/// Decode a compressed digest back into Entry structs (up to out.len entries).
pub fn decodeDigest(src: []const u8, out: []Entry) usize {
    if (src.len < 2 or out.len == 0) return 0;

    const header = std.mem.readInt(u16, src[0..2], .little);
    const flags: u16 = header >> digest_flag_shift;
    const target = header & digest_count_mask;
    const use_delta_ids = (flags & digest_flag_delta_ids) != 0;
    const use_compact_hlc = (flags & digest_flag_compact_hlc) != 0;

    var cursor: usize = 2;
    var base_wall: u64 = 0;
    if (use_compact_hlc and target > 0) {
        base_wall = readVarint(src, &cursor) orelse return 0;
    }

    var idx: usize = 0;
    var prev_id: u64 = 0;

    while (idx < out.len and idx < target) {
        const raw_id = readVarint(src, &cursor) orelse break;
        const id = if (use_delta_ids) prev_id + raw_id else raw_id;
        prev_id = id;

        const version = if (use_compact_hlc) blk: {
            const wall_delta = readVarint(src, &cursor) orelse break;
            const logical = readVarint(src, &cursor) orelse break;
            const wall = base_wall + wall_delta;
            const packed_value: u64 = (wall << 16) | (logical & 0xffff);
            break :blk packed_value;
        } else readVarint(src, &cursor) orelse break;

        out[idx] = .{ .id = id, .version = version };
        idx += 1;
    }

    return idx;
}

/// Pack multiple services into a DeployBatch payload (count + [version|service]*).
fn encodeDeployBatch(entries: []const Entry, service_data: *const ServiceData, dest: []u8) u16 {
    if (dest.len == 0) return 0;

    var cursor: usize = 1; // reserve byte 0 for count
    var written: u8 = 0;

    for (entries) |entry| {
        const svc = service_data.get(entry.id) orelse continue;
        const svc_bytes = std.mem.asBytes(&svc);
        const needed = 8 + svc_bytes.len;
        if (cursor + needed > dest.len) break;

        std.mem.writeInt(
            u64,
            @as(*[8]u8, @ptrCast(dest[cursor..].ptr)),
            entry.version,
            .little,
        );
        cursor += 8;
        @memcpy(dest[cursor .. cursor + svc_bytes.len], svc_bytes);
        cursor += svc_bytes.len;
        written += 1;
    }

    dest[0] = written;
    return if (written == 0) 0 else @intCast(cursor);
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

test "digest delta+compact handles unsorted ids and hlc payloads" {
    var payload: [952]u8 = undefined;
    var entries = [_]Entry{
        .{ .id = 42, .version = (Hlc{ .wall = 10_000, .logical = 1 }).pack() },
        .{ .id = 5, .version = (Hlc{ .wall = 9_900, .logical = 2 }).pack() },
        .{ .id = 17, .version = (Hlc{ .wall = 10_050, .logical = 0 }).pack() },
    };

    const used_bytes: u16 = encodeDigest(entries[0..], payload[0..]);
    const encoded_len: usize = @intCast(used_bytes);

    var decoded: [3]Entry = undefined;
    const decoded_len = decodeDigest(payload[0..encoded_len], decoded[0..]);
    try std.testing.expectEqual(@as(usize, entries.len), decoded_len);

    // sort expected by id to compare against delta-coded output
    std.sort.block(Entry, entries[0..], {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.id < b.id;
        }
    }.lessThan);

    for (entries, 0..) |expected, i| {
        try std.testing.expectEqual(expected.id, decoded[i].id);
        try std.testing.expectEqual(expected.version, decoded[i].version);
    }
}

pub const OutboundPacket = struct {
    packet: Packet,
    recipient: ?[32]u8 = null,
};

/// Fixed-length list that mimics a tiny subset of std.ArrayList for zero-alloc mode.
pub const FixedOutboundList = struct {
    buffer: [ZeroAllocCaps.max_outbox]OutboundPacket = undefined,
    items: []OutboundPacket = &[_]OutboundPacket{},
    len: usize = 0,

    pub fn init() FixedOutboundList {
        var list = FixedOutboundList{};
        list.items = list.buffer[0..0];
        return list;
    }

    pub fn append(self: *FixedOutboundList, allocator: std.mem.Allocator, value: OutboundPacket) !void {
        _ = allocator;
        if (self.len == self.buffer.len) return error.OutOfMemory;
        self.buffer[self.len] = value;
        self.len += 1;
        self.items = self.buffer[0..self.len];
    }

    pub fn clearRetainingCapacity(self: *FixedOutboundList) void {
        self.len = 0;
        self.items = self.buffer[0..0];
    }

    pub fn deinit(self: *FixedOutboundList, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.clearRetainingCapacity();
    }
};

/// Fixed-capacity ring buffer for zero-alloc mode; not yet wired into Node.
pub const FixedOutbox = struct {
    buf: [ZeroAllocCaps.max_outbox]OutboundPacket = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn reset(self: *FixedOutbox) void {
        self.head = 0;
        self.len = 0;
    }

    pub fn isFull(self: *FixedOutbox) bool {
        return self.len == self.buf.len;
    }

    pub fn isEmpty(self: *FixedOutbox) bool {
        return self.len == 0;
    }

    pub fn append(self: *FixedOutbox, pkt: OutboundPacket) bool {
        if (self.isFull()) return false;
        const idx = (self.head + self.len) % self.buf.len;
        self.buf[idx] = pkt;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *FixedOutbox) ?OutboundPacket {
        if (self.isEmpty()) return null;
        const pkt = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        return pkt;
    }
};

const MissingItem = struct {
    id: u64,
    source_peer: [32]u8,
};

/// Fixed-capacity missing queue for zero-alloc mode; not yet wired into Node.
pub const FixedMissingQueue = struct {
    buf: [ZeroAllocCaps.max_missing]MissingItem = undefined,
    len: usize = 0,

    pub fn reset(self: *FixedMissingQueue) void {
        self.len = 0;
    }

    pub fn append(self: *FixedMissingQueue, item: MissingItem) bool {
        if (self.len == self.buf.len) return false;
        self.buf[self.len] = item;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *FixedMissingQueue) ?MissingItem {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.buf[self.len];
    }
};

/// Distributed node state and behavior: storage, replication, and networking hooks.
pub const Node = struct {
    id: u16,
    allocator: std.mem.Allocator,
    identity: Identity,
    wal: WAL,
    knowledge: u64 = 0,
    hlc: Hlc,
    store: Store,
    service_data: ServiceData,
    last_deployed_id: u64 = 0,
    forced_sync_id: u64 = 0,
    forced_sync_version: u64 = 0,
    rng: std.Random.DefaultPrng,
    context: *anyopaque,
    on_deploy: *const fn (ctx: *anyopaque, service: Service) anyerror!void,

    // Buffer of outstanding items we need to request from peers. Keep it large enough
    // to cover the expected fanout in simulations so we don't silently drop work.
    missing_list: [ZeroAllocCaps.max_missing]MissingItem = [_]MissingItem{.{ .id = 0, .source_peer = [_]u8{0} ** 32 }} ** ZeroAllocCaps.max_missing,
    missing_count: usize = 0,
    dirty_sync: bool = false,
    tick_counter: u64 = 0,
    dirty_stuck_ticks: u64 = 0,
    pending_forced: [32]Entry = [_]Entry{.{ .id = 0, .version = 0 }} ** 32,
    pending_forced_len: usize = 0,
    emergency_forced: [32]Entry = [_]Entry{.{ .id = 0, .version = 0 }} ** 32,
    emergency_forced_len: usize = 0,
    blackbox: [64]Entry = [_]Entry{.{ .id = 0, .version = 0 }} ** 64,
    blackbox_idx: usize = 0,
    gossip_fanout: u8 = 2,
    sync_snapshot_interval: u16 = 5,
    sync_sample_size: u16 = 512,
    control_interval: u16 = 2,
    control_sample_size: u16 = 256,

    /// Construct a node with deterministic identity, WAL-backed knowledge, and CRDT state.
    pub fn init(
        id: u16,
        allocator: std.mem.Allocator,
        disk_buffer: []u8,
        context: *anyopaque,
        on_deploy_fn: *const fn (*anyopaque, Service) anyerror!void,
    ) !Node {
        const store_init = blk: {
            if (use_zero_alloc) {
                break :blk Store.init();
            }
            break :blk Store.init(allocator);
        };
        const service_data_init = blk: {
            if (use_zero_alloc) {
                break :blk ServiceData.init();
            }
            break :blk ServiceData.init(allocator);
        };

        var node = Node{
            .id = id,
            .allocator = allocator,
            .identity = Identity.initDeterministic(id),
            .wal = WAL.init(disk_buffer),
            .knowledge = 0,
            .hlc = Hlc.initNow(),
            .store = store_init,
            .service_data = service_data_init,
            .last_deployed_id = 0,
            .rng = std.Random.DefaultPrng.init(id),
            .context = context,
            .on_deploy = on_deploy_fn,
            .gossip_fanout = readFanoutEnv() orelse 2,
            // Defaults tuned for aggressive sync; env vars can override.
            .sync_snapshot_interval = readU16Env("MYCO_SYNC_SNAPSHOT_INTERVAL") orelse 20,
            .sync_sample_size = readU16Env("MYCO_SYNC_SAMPLE_SIZE") orelse 64,
            .control_interval = readU16Env("MYCO_CONTROL_INTERVAL") orelse 5,
            .control_sample_size = readU16Env("MYCO_CONTROL_SAMPLE_SIZE") orelse 32,
        };
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
            const pk = node.identity.key_pair.public_key.toBytes();
            const prefix: u32 = std.mem.readInt(u32, pk[0..4], .big);
            std.debug.print("[gossip] node id={d} pubkey_prefix={x}\n", .{ id, prefix });
        }
        const recovered_state = node.wal.recover();
        if (recovered_state > 0) {
            node.knowledge = recovered_state;
        } else {
            node.knowledge = id;
            try node.wal.append(node.knowledge);
        }
        return node;
    }

    fn nextVersion(self: *Node) u64 {
        return self.hlc.nextNow();
    }

    fn observeVersion(self: *Node, version: u64) void {
        _ = self.hlc.observeNow(version);
    }

    pub fn storeCount(self: *const Node) usize {
        return self.store.count();
    }

    pub fn storeIterator(self: *Node) StoreIterator {
        return self.store.iterator();
    }

    fn dirtySlice(self: *Node) []Entry {
        if (use_zero_alloc) {
            return self.store.dirty[0..self.store.dirty_len];
        }
        return self.store.dirty.items;
    }

    fn recordBlackbox(self: *Node, entry: Entry) void {
        self.blackbox[self.blackbox_idx % self.blackbox.len] = entry;
        self.blackbox_idx += 1;
    }

    fn logDirty(self: *Node, label: []const u8) void {
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") == null) return;
        const slice = self.dirtySlice();
        std.debug.print("[gossip] {s} dirty len={d}\n", .{ label, slice.len });
        const max_entries = @min(slice.len, @as(usize, 4));
        var i: usize = 0;
        while (i < max_entries) : (i += 1) {
            std.debug.print("  [{d}] id={d} ver={d}\n", .{ i, slice[i].id, slice[i].version });
        }
        if (slice.len > max_entries) {
            std.debug.print("  ...\n", .{});
        }
    }

    /// Locally deploy a service and propagate it via gossip if it is new or updated.
    pub fn injectService(self: *Node, service: Service) !bool {
        const version = self.nextVersion();
        if (try self.store.update(service.id, version)) {
            self.last_deployed_id = service.id;
            self.forced_sync_id = service.id;
            self.forced_sync_version = version;
            try self.service_data.put(service.id, service);
            self.on_deploy(self.context, service) catch {};
            self.dirty_sync = true;
            if (self.pending_forced_len < self.pending_forced.len) {
                self.pending_forced[self.pending_forced_len] = .{ .id = service.id, .version = version };
                self.pending_forced_len += 1;
            }
            if (self.emergency_forced_len < self.emergency_forced.len) {
                self.emergency_forced[self.emergency_forced_len] = .{ .id = service.id, .version = version };
                self.emergency_forced_len += 1;
            }
            self.recordBlackbox(.{ .id = service.id, .version = version });
            self.logDirty("inject dirty");
            if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                std.debug.print("[gossip] local deploy id={d} ver={d}\n", .{ service.id, version });
            }
            return true;
        }
        return false;
    }

    /// Single tick of protocol logic: pull missing items, process inbound packets, gossip digest.
    pub fn tick(self: *Node, inputs: []const Packet, outputs: *OutboxList, output_allocator: std.mem.Allocator) !void {
        self.tick_counter += 1;
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.tick_counter % 50 == 0) {
            const max_bb = @min(self.blackbox.len, @as(usize, 8));
            std.debug.print("[gossip] blackbox (latest {d})\n", .{max_bb});
            var k: usize = 0;
            while (k < max_bb) : (k += 1) {
                const idx = (self.blackbox_idx + self.blackbox.len - k - 1) % self.blackbox.len;
                const entry = self.blackbox[idx];
                if (entry.id == 0) break;
                std.debug.print("  [bb {d}] id={d} ver={d}\n", .{ k, entry.id, entry.version });
            }
        }
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.tick_counter % 2 == 0) {
            const dirty = self.dirtySlice();
            if (dirty.len > 0 or self.pending_forced_len > 0 or self.emergency_forced_len > 0) {
                std.debug.print("[gossip] tick queues dirty={d} pending_forced={d} emergency={d}\n", .{ dirty.len, self.pending_forced_len, self.emergency_forced_len });
                const max_dirty = @min(dirty.len, @as(usize, 3));
                var i: usize = 0;
                while (i < max_dirty) : (i += 1) {
                    std.debug.print("  [dirty {d}] id={d} ver={d}\n", .{ i, dirty[i].id, dirty[i].version });
                }
                const max_forced = @min(self.pending_forced_len, @as(usize, 3));
                var j: usize = 0;
                while (j < max_forced) : (j += 1) {
                    std.debug.print("  [pending {d}] id={d} ver={d}\n", .{ j, self.pending_forced[j].id, self.pending_forced[j].version });
                }
                const max_emerg = @min(self.emergency_forced_len, @as(usize, 3));
                var e: usize = 0;
                while (e < max_emerg) : (e += 1) {
                    std.debug.print("  [emerg {d}] id={d} ver={d}\n", .{ e, self.emergency_forced[e].id, self.emergency_forced[e].version });
                }
            }
        }
        // 1. Process a few items from the "To-Do" list to accelerate catch-up.
        var missing_budget: usize = 64; // aggressive pull budget
        while (self.missing_count > 0 and missing_budget > 0) : (missing_budget -= 1) {
            self.missing_count -= 1;
            const item = self.missing_list[self.missing_count];
            if (self.store.getVersion(item.id) == 0) {
                var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                req.setPayload(item.id);
                req.payload_len = 8;
                // THIS IS THE CRITICAL FIX: Send the request DIRECTLY to the peer that has the data.
                try outputs.append(output_allocator, .{ .packet = req, .recipient = item.source_peer });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] pull missing id={d} remaining={d}\n", .{ item.id, self.missing_count });
                }
            }
        }

        // 2. Process incoming packets.
        for (inputs) |p| {
            switch (p.msg_type) {
                Headers.Deploy => {
                    if (p.payload_len < 8 + @sizeOf(Service)) continue;
                    const version = std.mem.readInt(u64, p.payload[0..8], .little);
                    self.observeVersion(version);
                    const service_bytes = p.payload[8 .. 8 + @sizeOf(Service)];
                    const service: *const Service = @ptrCast(@alignCast(service_bytes));
                    const incoming = Hlc.unpack(version);
                    const current = Hlc.unpack(self.store.getVersion(service.id));
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        std.debug.print("[gossip] recv deploy packet id={d} incoming={d} current={d}\n", .{ service.id, version, self.store.getVersion(service.id) });
                        var matched_missing = false;
                        var j: usize = 0;
                        while (j < self.missing_count) : (j += 1) {
                            if (self.missing_list[j].id == service.id) {
                                matched_missing = true;
                                break;
                            }
                        }
                        if (matched_missing) {
                            std.debug.print("[gossip] recv deploy packet matched missing id={d}\n", .{service.id});
                        }
                    }
                    if (Hlc.newer(incoming, current) and (try self.store.update(service.id, version))) {
                        self.last_deployed_id = service.id;
                        try self.service_data.put(service.id, service.*);
                        self.on_deploy(self.context, service.*) catch {};
                        self.dirty_sync = true;

                        // ACTIVE RUMOR MONGERING (Hot Potato)
                        for (0..self.gossip_fanout) |_| {
                            var forward = p;
                            forward.sender_pubkey = self.identity.key_pair.public_key.toBytes();
                            forward.payload_len = p.payload_len;
                            try outputs.append(output_allocator, .{ .packet = forward, .recipient = null });
                        }
                    } else if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        std.debug.print("[gossip] drop deploy packet id={d} incoming={d} current={d}\n", .{ service.id, version, self.store.getVersion(service.id) });
                    }
                },
                Headers.DeployBatch => {
                    const payload_len: usize = @min(@as(usize, p.payload_len), p.payload.len);
                    if (payload_len < 1 + 8 + @sizeOf(Service)) continue;

                    var cursor: usize = 1;
                    const count = p.payload[0];
                    var processed: u8 = 0;

                    while (processed < count and cursor + 8 + @sizeOf(Service) <= payload_len) {
                        const version = std.mem.readInt(
                            u64,
                            @as(*const [8]u8, @ptrCast(p.payload[cursor..].ptr)),
                            .little,
                        );
                        cursor += 8;

                        const svc_bytes = p.payload[cursor .. cursor + @sizeOf(Service)];
                        var service: Service = undefined;
                        @memcpy(std.mem.asBytes(&service), svc_bytes);
                        cursor += @sizeOf(Service);

                        self.observeVersion(version);
                        const incoming = Hlc.unpack(version);
                        const current = Hlc.unpack(self.store.getVersion(service.id));
                        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                            var matched_missing = false;
                            var j: usize = 0;
                            while (j < self.missing_count) : (j += 1) {
                                if (self.missing_list[j].id == service.id) {
                                    matched_missing = true;
                                    break;
                                }
                            }
                            if (matched_missing) {
                                std.debug.print("[gossip] recv deploy matches missing id={d}\n", .{service.id});
                            }
                        }
                        if (Hlc.newer(incoming, current) and (try self.store.update(service.id, version))) {
                            self.last_deployed_id = service.id;
                            self.forced_sync_id = service.id;
                            self.forced_sync_version = version;
                            try self.service_data.put(service.id, service);
                            self.on_deploy(self.context, service) catch {};
                            self.dirty_sync = true;
                            if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                std.debug.print("[gossip] recv deploy id={d} ver={d} (applied)\n", .{ service.id, version });
                            }
                        } else if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                            std.debug.print("[gossip] drop deploy id={d} incoming={d} current={d}\n", .{ service.id, version, self.store.getVersion(service.id) });
                        }

                        processed += 1;
                    }
                },
                Headers.Request => {
                    const requested_id = p.getPayload();
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        std.debug.print("[gossip] recv request id={d}\n", .{requested_id});
                    }
                    if (self.service_data.get(requested_id)) |service_value| {
                        var reply = Packet{ .msg_type = Headers.Deploy, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                        const version = self.store.getVersion(requested_id);
                        std.mem.writeInt(u64, reply.payload[0..8], version, .little);
                        const s_bytes = std.mem.asBytes(&service_value);
                        @memcpy(reply.payload[8 .. 8 + @sizeOf(Service)], s_bytes);
                        reply.payload_len = @intCast(8 + @sizeOf(Service));
                        try outputs.append(output_allocator, .{ .packet = reply, .recipient = p.sender_pubkey });
                        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                            const dest: u32 = std.mem.readInt(u32, p.sender_pubkey[0..4], .big);
                            std.debug.print("[gossip] reply request id={d} ver={d} dest={x}\n", .{ requested_id, version, dest });
                        }
                    } else {
                        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                            std.debug.print("[gossip] request for unknown id={d}\n", .{requested_id});
                        }
                    }
                },
                Headers.Sync, Headers.Control => {
                    var decoded: [1024]Entry = undefined;
                    @memset(&decoded, Entry{ .id = 0, .version = 0 });
                    const payload_len: usize = @min(@as(usize, p.payload_len), p.payload.len);
                    const payload = p.payload[0..payload_len];
                    const decoded_len = decodeDigest(payload, decoded[0..]);
                    const label = if (p.msg_type == Headers.Sync) "recv sync" else "recv ctrl";
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and decoded_len == 0 and payload_len > 0) {
                        const header: u16 = if (payload_len >= 2) std.mem.readInt(u16, payload[0..2], .little) else 0;
                        std.debug.print("[gossip] decode digest empty payload_len={d} header=0x{x}\n", .{ payload_len, header });
                    }
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        const src_prefix: u32 = std.mem.readInt(u32, p.sender_pubkey[0..4], .big);
                        std.debug.print("[gossip] recv {s} from={x} entries={d}\n", .{ label, src_prefix, decoded_len });
                    }
                    logDigestEntries(label, decoded[0..decoded_len]);
                    dumpBuffer(label, decoded[0..decoded_len]);

                    for (decoded[0..decoded_len]) |entry| {
                        if (entry.id == 0) continue;
                        self.observeVersion(entry.version);
                        const my_version = Hlc.unpack(self.store.getVersion(entry.id));
                        const incoming = Hlc.unpack(entry.version);

                        if (Hlc.newer(incoming, my_version)) {
                            // I am behind. Add to my to-do list if we don't already have it.
                            var already_tracked = false;
                            for (self.missing_list[0..self.missing_count]) |missing| {
                                if (missing.id == entry.id) {
                                    already_tracked = true;
                                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                        std.debug.print("[gossip] missing already tracked id={d}\n", .{entry.id});
                                    }
                                    break;
                                }
                            }

                            if (!already_tracked) {
                                if (self.missing_count < self.missing_list.len) {
                                    self.missing_list[self.missing_count] = .{
                                        .id = entry.id,
                                        .source_peer = p.sender_pubkey,
                                    };
                                    self.missing_count += 1;
                                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                        std.debug.print("[gossip] missing enqueue id={d}\n", .{entry.id});
                                    }
                                } else {
                                    // Queue is saturated; replace a random slot to avoid starvation.
                                    const idx = self.rng.random().intRangeAtMost(usize, 0, self.missing_list.len - 1);
                                    self.missing_list[idx] = .{
                                        .id = entry.id,
                                        .source_peer = p.sender_pubkey,
                                    };
                                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                        std.debug.print("[gossip] missing replace id={d}\n", .{entry.id});
                                    }
                                }
                            }

                            // Act immediately: request the missing item from the advertising peer.
                            // This avoids reliance on the queued pull path when the queue stays empty.
                            var req = Packet{ .msg_type = Headers.Request, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                            req.setPayload(entry.id);
                            req.payload_len = 8;
                            try outputs.append(output_allocator, .{ .packet = req, .recipient = p.sender_pubkey });
                            if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                std.debug.print("[gossip] pull request id={d} from peer version={d}\n", .{ entry.id, entry.version });
                                std.debug.print("[gossip] missing queue size={d}\n", .{self.missing_count});
                            }
                        } else {
                            if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                                std.debug.print("[gossip] skip incoming id={d} my_ver={d} incoming={d}\n", .{ entry.id, self.store.getVersion(entry.id), entry.version });
                            }
                        }
                    }
                },
                else => {},
            }
        }

        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.missing_count > 0 and self.tick_counter % 3 == 0) {
            const dump_len = @min(self.missing_count, @as(usize, 8));
            std.debug.print("[gossip] missing queue dump count={d}\n", .{self.missing_count});
            var i: usize = 0;
            while (i < dump_len) : (i += 1) {
                const cur_ver = self.store.getVersion(self.missing_list[i].id);
                std.debug.print("  [{d}] id={d} cur_ver={d}\n", .{ i, self.missing_list[i].id, cur_ver });
            }
        }

        // Dirty queue watchdog: log periodically if entries are stuck.
        {
            const slice = self.dirtySlice();
            if (slice.len > 0) {
                self.dirty_stuck_ticks += 1;
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.dirty_stuck_ticks % 5 == 0) {
                    std.debug.print("[gossip] dirty queue still non-empty len={d}\n", .{slice.len});
                    const max_entries = @min(slice.len, @as(usize, 4));
                    var i: usize = 0;
                    while (i < max_entries) : (i += 1) {
                        std.debug.print("  [{d}] id={d} ver={d}\n", .{ i, slice[i].id, slice[i].version });
                    }
                }
            } else {
                self.dirty_stuck_ticks = 0;
            }
        }

        // 3. Periodic Gossip for discovery (very aggressive).
        // Emit any pending forced sync packets from recent local deploys before draining deltas.
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.pending_forced_len > 0) {
            std.debug.print("[gossip] pending forced count={d}\n", .{self.pending_forced_len});
        }
        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null and self.emergency_forced_len > 0) {
            std.debug.print("[gossip] emergency forced count={d}\n", .{self.emergency_forced_len});
        }
        if (self.emergency_forced_len > 0) {
            var e: usize = 0;
            while (e < self.emergency_forced_len) : (e += 1) {
                var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                var entry_buf: [1]Entry = .{self.emergency_forced[e]};
                const used_forced = encodeDigest(entry_buf[0..], p.payload[0..]);
                p.payload_len = @intCast(used_forced);
                try outputs.append(output_allocator, .{ .packet = p });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] emergency forced sync id={d} ver={d} bytes={d}\n", .{ entry_buf[0].id, entry_buf[0].version, p.payload_len });
                }
                logDigestEntries("emergency forced sync", entry_buf[0..]);
                self.recordBlackbox(entry_buf[0]);
            }
            self.emergency_forced_len = 0;
        }
        if (self.pending_forced_len > 0) {
            var i: usize = 0;
            while (i < self.pending_forced_len) : (i += 1) {
                var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                var entry_buf: [1]Entry = .{self.pending_forced[i]};
                const used_forced = encodeDigest(entry_buf[0..], p.payload[0..]);
                p.payload_len = @intCast(used_forced);
                try outputs.append(output_allocator, .{ .packet = p });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] inject forced sync id={d} ver={d} bytes={d}\n", .{ entry_buf[0].id, entry_buf[0].version, p.payload_len });
                }
                logDigestEntries("inject forced sync", entry_buf[0..]);
            }
            self.pending_forced_len = 0;
        }

        // Send delta digest of recent updates; reuse the delta for control piggybacking to avoid extra drains.
        var delta_buf: [1024]Entry = undefined;
        @memset(&delta_buf, Entry{ .id = 0, .version = 0 });
        self.logDirty("pre-drain dirty");
        const delta_len = self.store.drainDirty(delta_buf[0..]);
        dumpBuffer("delta buffer", delta_buf[0..delta_len]);

        if (delta_len > 0) {
            var batch = Packet{ .msg_type = Headers.DeployBatch, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            const used = encodeDeployBatch(delta_buf[0..delta_len], &self.service_data, batch.payload[0..]);
            if (used > 0) {
                batch.payload_len = used;
                try outputs.append(output_allocator, .{ .packet = batch });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] deploy batch sent entries={d} bytes={d}\n", .{ delta_len, used });
                    const dump_len = @min(delta_len, @as(usize, 8));
                    var i: usize = 0;
                    while (i < dump_len) : (i += 1) {
                        std.debug.print("  [delta {d}] id={d} ver={d}\n", .{ i, delta_buf[i].id, delta_buf[i].version });
                    }
                }
                logDigestEntries("delta entries", delta_buf[0..delta_len]);
            }
            // Ensure the latest local deploy is explicitly advertised even when a delta batch was sent.
            if (self.forced_sync_id != 0 and self.forced_sync_version != 0) {
                var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                var entry_buf: [1]Entry = .{.{
                    .id = self.forced_sync_id,
                    .version = self.forced_sync_version,
                }};
                dumpBuffer("forced sync entry (with delta)", entry_buf[0..]);
                const used_forced = encodeDigest(entry_buf[0..], p.payload[0..]);
                p.payload_len = @intCast(used_forced);
                try outputs.append(output_allocator, .{ .packet = p });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] forced sync after delta id={d} ver={d} bytes={d}\n", .{ self.forced_sync_id, self.forced_sync_version, p.payload_len });
                }
                logDigestEntries("forced sync entries", entry_buf[0..]);
                self.forced_sync_id = 0;
                self.forced_sync_version = 0;
                self.dirty_sync = false;
            }
        } else {
            // If no deltas but we recently deployed, force a tiny sync to nudge peers.
            if (self.dirty_sync) {
                var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
                if (self.forced_sync_id != 0 and self.forced_sync_version != 0) {
                    var entry_buf: [1]Entry = .{.{
                        .id = self.forced_sync_id,
                        .version = self.forced_sync_version,
                    }};
                    dumpBuffer("forced sync entry", entry_buf[0..]);
                    const used = encodeDigest(entry_buf[0..], p.payload[0..]);
                    p.payload_len = @intCast(used);
                    try outputs.append(output_allocator, .{ .packet = p });
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        std.debug.print("[gossip] forced sync single id={d} ver={d} bytes={d}\n", .{ self.forced_sync_id, self.forced_sync_version, p.payload_len });
                    }
                    logDigestEntries("forced sync entries", entry_buf[0..]);
                } else {
                    var sample_buf: [8]Entry = undefined;
                    @memset(&sample_buf, Entry{ .id = 0, .version = 0 });
                    const sample_len = self.store.populateDigest(sample_buf[0..sample_buf.len], self.rng.random());
                    dumpBuffer("forced sync sample", sample_buf[0..sample_len]);
                    if (sample_len > 0) {
                        const used = encodeDigest(sample_buf[0..sample_len], p.payload[0..]);
                        p.payload_len = @intCast(used);
                        try outputs.append(output_allocator, .{ .packet = p });
                        if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                            std.debug.print("[gossip] forced sync entries={d} bytes={d}\n", .{ sample_len, p.payload_len });
                        }
                        logDigestEntries("forced sync entries", sample_buf[0..sample_len]);
                    }
                }
                self.forced_sync_id = 0;
                self.forced_sync_version = 0;
                self.dirty_sync = false;
            }
        }

        // Sync: prefer deltas; otherwise send a sampled snapshot on the configured cadence.
        {
            var p = Packet{ .msg_type = Headers.Sync, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            if (delta_len > 0) {
                const used = encodeDigest(delta_buf[0..delta_len], p.payload[0..]);
                p.payload_len = @intCast(used);
                try outputs.append(output_allocator, .{ .packet = p });
                logSend("sync delta send", delta_buf[0..delta_len], null);
                self.dirty_sync = false;
            } else if (self.tick_counter % self.sync_snapshot_interval == 0) {
                var sample_buf: [1024]Entry = undefined;
                @memset(&sample_buf, Entry{ .id = 0, .version = 0 });
                const sample_cap: usize = @min(sample_buf.len, self.sync_sample_size);
                const sample_len = self.store.populateDigest(sample_buf[0..sample_cap], self.rng.random());
                dumpBuffer("sync sample buf", sample_buf[0..sample_len]);
                if (sample_len > 0) {
                    const used = encodeDigest(sample_buf[0..sample_len], p.payload[0..]);
                    p.payload_len = @intCast(used);
                    try outputs.append(output_allocator, .{ .packet = p });
                    logSend("sync sample", sample_buf[0..sample_len], null);
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        const dump_len = @min(sample_len, @as(usize, 8));
                        var i: usize = 0;
                        while (i < dump_len) : (i += 1) {
                            std.debug.print("  [sync sample {d}] id={d} ver={d}\n", .{ i, sample_buf[i].id, sample_buf[i].version });
                        }
                    }
                }
            }
        }

        // Lightweight health/control message with a digest piggybacked frequently (delta if available, otherwise a small sample).
        if (self.tick_counter % self.control_interval == 0) {
            var p = Packet{ .msg_type = Headers.Control, .sender_pubkey = self.identity.key_pair.public_key.toBytes() };
            var used: u16 = 0;
            if (delta_len > 0) {
                used = encodeDigest(delta_buf[0..delta_len], p.payload[0..]);
                logSend("control delta", delta_buf[0..delta_len], null);
            } else {
                var ctrl_buf: [256]Entry = undefined;
                @memset(&ctrl_buf, Entry{ .id = 0, .version = 0 });
                const sample_cap: usize = @min(ctrl_buf.len, self.control_sample_size);
                const sample_len = self.store.populateDigest(ctrl_buf[0..sample_cap], self.rng.random());
                dumpBuffer("control sample buf", ctrl_buf[0..sample_len]);
                if (sample_len > 0) {
                    used = encodeDigest(ctrl_buf[0..sample_len], p.payload[0..]);
                    logSend("control sample", ctrl_buf[0..sample_len], null);
                    if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                        const dump_len = @min(sample_len, @as(usize, 8));
                        var i: usize = 0;
                        while (i < dump_len) : (i += 1) {
                            std.debug.print("  [ctrl sample {d}] id={d} ver={d}\n", .{ i, ctrl_buf[i].id, ctrl_buf[i].version });
                        }
                    }
                }
            }
            if (used > 0) {
                p.payload_len = used;
                try outputs.append(output_allocator, .{ .packet = p });
                if (std.posix.getenv("MYCO_GOSSIP_DEBUG") != null) {
                    std.debug.print("[gossip] control entries bytes={d}\n", .{p.payload_len});
                }
            }
        }
    }
};

fn readFanoutEnv() ?u8 {
    if (std.posix.getenv("MYCO_GOSSIP_FANOUT")) |bytes| {
        return std.fmt.parseInt(u8, bytes, 10) catch null;
    }
    return null;
}

// For memory-sizing reference:
// - delta_buf: 1024 entries (~16 KiB) used for dirty drain and control piggyback.
// - decode buffer: 1024 entries (~16 KiB) for incoming sync/control.
// - sync sample buffer: 1024 entries (~16 KiB) sampled on snapshot interval.
// - control sample buffer: 256 entries (~4 KiB) when no delta is available.
// These are stack-allocated per tick; keep intervals/sizes reasonable for stack limits.

fn readU16Env(name: []const u8) ?u16 {
    if (std.posix.getenv(name)) |bytes| {
        return std.fmt.parseInt(u16, bytes, 10) catch null;
    }
    return null;
}
