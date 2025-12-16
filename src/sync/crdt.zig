const std = @import("std");

pub const Entry = extern struct {
    id: u64,
    version: u64,
};

pub const ServiceStore = struct {
    allocator: std.mem.Allocator,
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

    pub fn update(self: *ServiceStore, id: u64, version: u64) !bool {
        const result = try self.versions.getOrPut(id);
        if (!result.found_existing) {
            result.value_ptr.* = version;
            return true;
        } else {
            if (version > result.value_ptr.*) {
                result.value_ptr.* = version;
                return true;
            }
        }
        return false;
    }

    pub fn getVersion(self: *ServiceStore, id: u64) u64 {
        return self.versions.get(id) orelse 0;
    }

    /// FIX: Implement true random sampling using the Reservoir Sampling algorithm.
    /// This is a zero-allocation, single-pass algorithm that guarantees a fair sample.
    pub fn populateDigest(self: *ServiceStore, buffer: []Entry, rand: std.Random) usize {
        const k = buffer.len;
        if (k == 0) return 0;

        var count: usize = 0;
        var it = self.versions.iterator();

        // 1. Fill the reservoir (the buffer) with the first 'k' items.
        while (count < k) {
            const kv = it.next() orelse break;
            buffer[count] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            count += 1;
        }

        // If the map had fewer items than the buffer, we're done.
        if (count < k) {
            return count;
        }
        
        // 2. For all remaining items in the stream (from k+1 to n)...
        // 'i' represents the total number of items seen so far.
        var i = k;
        while (it.next()) |kv| {
            // Generate a random number 'j' between 0 and 'i'.
            const j = rand.intRangeAtMost(usize, 0, i);
            
            // If 'j' falls within the reservoir's bounds (0 to k-1)...
            if (j < k) {
                // ...replace the element at that position.
                buffer[j] = .{ .id = kv.key_ptr.*, .version = kv.value_ptr.* };
            }
            i += 1;
        }

        return k;
    }
};
