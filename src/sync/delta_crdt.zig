// Delta-based CRDT store for services. Packs HLC (wall ms | logical) into u64.
// This file implements a general delta-based CRDT (Conflict-Free Replicated Data Type)
// store, offering a dynamic approach to managing versioned key-value pairs.
// It leverages `std.AutoHashMap` for storing service versions and
// `std.ArrayListUnmanaged` for efficiently tracking dirty (changed) entries.
// This module facilitates the synchronization of changes in a distributed
// environment, packing Hybrid Logical Clock (HLC) timestamps into `u64`
// versions for robust conflict resolution.
//
const std = @import("std");
pub const Hlc = @import("hlc.zig").Hlc;

pub const Entry = struct { id: u64, version: u64 };

pub const DeltaStore = struct {
    allocator: std.mem.Allocator,
    versions: std.AutoHashMap(u64, u64),
    dirty: std.ArrayListUnmanaged(Entry),

    pub fn init(allocator: std.mem.Allocator) DeltaStore {
        return .{
            .allocator = allocator,
            .versions = std.AutoHashMap(u64, u64).init(allocator),
            .dirty = .{},
        };
    }

    pub fn deinit(self: *DeltaStore) void {
        self.versions.deinit();
        self.dirty.deinit(self.allocator);
    }

    pub fn update(self: *DeltaStore, id: u64, version: u64) !bool {
        const current = self.versions.get(id) orelse 0;
        if (current == 0 or Hlc.newer(Hlc.unpack(version), Hlc.unpack(current))) {
            try self.versions.put(self.allocator, id, version);
            try self.dirty.append(self.allocator, .{ .id = id, .version = version });
            return true;
        }
        return false;
    }

    pub fn get(self: *DeltaStore, id: u64) u64 {
        return self.versions.get(id) orelse 0;
    }

    pub fn drainDirty(self: *DeltaStore, out: []Entry) usize {
        const take = @min(out.len, self.dirty.items.len);
        if (take == 0) return 0;
        std.mem.copyForwards(Entry, out[0..take], self.dirty.items[0..take]);
        const remain = self.dirty.items.len - take;
        if (remain > 0) {
            std.mem.copyForwards(Entry, self.dirty.items[0..remain], self.dirty.items[take .. take + remain]);
        }
        self.dirty.items.len = remain;
        return take;
    }
};
