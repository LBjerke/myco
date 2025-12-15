const std = @import("std");

/// A lightweight metadata entry for syncing.
/// 16 bytes per entry.
pub const Entry = extern struct {
    id: u64,
    version: u64,
};

/// The Service Store (CRDT).
/// Maintains the "Truth" of what is running.
pub const ServiceStore = struct {
    allocator: std.mem.Allocator,
    
    // Map of ServiceID -> Version
    // We only store metadata here. The full Service struct is in the WAL/Disk.
    // In Phase 5, we keep this in RAM for fast lookups.
    versions: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator) ServiceStore {
        return .{
            .allocator = allocator,
            .versions = std.AutoHashMap(u64, u64).init(allocator),
        };
    }

    pub fn deinit(self: *ServiceStore) void {
        self.versions.deinit();
    }

    /// Update a service version (CRDT Merge).
    /// Returns true if this was a new or newer entry (State Changed).
    pub fn update(self: *ServiceStore, id: u64, version: u64) !bool {
        const result = try self.versions.getOrPut(id);
        if (!result.found_existing) {
            // New entry
            result.value_ptr.* = version;
            return true;
        } else {
            // Existing entry: Last-Write-Wins (High Version Wins)
            if (version > result.value_ptr.*) {
                result.value_ptr.* = version;
                return true;
            }
        }
        return false;
    }

    /// Get version of an ID. Returns 0 if unknown.
    pub fn getVersion(self: *ServiceStore, id: u64) u64 {
        return self.versions.get(id) orelse 0;
    }

    /// Generate a "Digest" - a random subset of our knowledge.
    /// We fill the provided slice with up to 'max' entries.
    /// Returns the number of entries written.
    pub fn populateDigest(self: *ServiceStore, buffer: []Entry, rand: std.Random) usize {
        var count: usize = 0;
        var it = self.versions.iterator();
        
        // Simple reservoir sampling or just linear scan with skip for now.
        // For a true production system, we'd use a random iterator.
        // Here we just grab the first N that fit, effectively. 
        // To make it "Gossip", in the Node we will randomize the iteration or start point.
        while (it.next()) |kv| {
            if (count >= buffer.len) break;
            
            // 50% chance to skip to simulate random subset gossip if we have many items
            if (self.versions.count() > buffer.len and rand.boolean()) continue;

            buffer[count] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            count += 1;
        }
        return count;
    }
};
