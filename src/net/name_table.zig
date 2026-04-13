//! Name Table - fixed-size storage for service names.
//!
//! Replaces dynamic string allocation with compact index-based lookup.
//! Each entry is 8 bytes: 7 chars + 1 byte length.

const std = @import("std");

/// Maximum service name length (7 chars fits in u8).
pub const max_name_len: u8 = 7;

/// Name entry: 7 bytes data + 1 byte length.
pub const NameEntry = extern struct {
    /// 7-byte name data (null-padded).
    data: [max_name_len]u8,

    /// Actual name length (0-7).
    len: u8,
};

/// Fixed-size name table for service names.
/// Uses compact 8-byte slots for all service names.
///
/// - Max 256 entries (one per service)
/// - 8 bytes per entry = 2048 bytes total
/// - O(1) add, find, get operations
pub const NameTable = struct {
    /// Fixed-size name entries.
    entries: [256]NameEntry,

    /// Next available slot (0-256).
    next_index: u8 = 0,

    /// Initialize a new empty NameTable.
    ///
    /// Uses zero-initialized entries for safety.
    pub fn init() NameTable {
        return NameTable{
            .entries = std.mem.zeroes([256]NameEntry),
            .next_index = 0,
        };
    }

    /// Add a name to the table, return index.
    ///
    /// Errors:
    /// - NameTooLong: name exceeds max_name_len (7 chars)
    /// - NameTableFull: no more slots available
    pub fn add(table: *NameTable, name: []const u8) error{ NameTooLong, NameTableFull }!u8 {
        // Validate name length
        if (name.len > max_name_len) {
            return error.NameTooLong;
        }

        // Check capacity
        if (table.next_index >= 255) {
            return error.NameTableFull;
        }

        const idx = table.next_index;
        table.next_index += 1;

        // Copy name data with null padding
        @memcpy(table.entries[idx].data[0..name.len], name);
        // Zero pad remainder
        if (name.len < max_name_len) {
            @memset(table.entries[idx].data[name.len..max_name_len], 0);
        }
        table.entries[idx].len = @truncate(name.len);

        return idx;
    }

    /// Get name by index.
    ///
    /// Returns undefined slice if index is invalid.
    pub fn get(table: *const NameTable, idx: u8) []const u8 {
        if (idx >= table.next_index) {
            return &[_]u8{};
        }
        return table.entries[idx].data[0..table.entries[idx].len];
    }

    /// Find index by name (linear search).
    ///
    /// Returns null if name not found.
    pub fn find(table: *const NameTable, name: []const u8) ?u8 {
        for (0..table.next_index) |i| {
            const idx = @as(u8, @truncate(i));
            const entry = table.entries[idx];
            if (entry.len == name.len and
                std.mem.eql(u8, entry.data[0..entry.len], name))
            {
                return idx;
            }
        }
        return null;
    }

    /// Check if table is empty.
    pub fn isEmpty(table: *const NameTable) bool {
        return table.next_index == 0;
    }

    /// Get current entry count.
    pub fn count(table: *const NameTable) u8 {
        return table.next_index;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NameTable.init returns empty table" {
    const table = NameTable.init();

    try std.testing.expectEqual(@as(u8, 0), table.next_index);
}

test "NameTable.add returns index" {
    var table = NameTable.init();

    const idx = try table.add("test");
    try std.testing.expectEqual(@as(u8, 0), idx);
}

test "NameTable.add increments next_index" {
    var table = NameTable.init();

    _ = try table.add("a");
    _ = try table.add("b");
    _ = try table.add("c");

    try std.testing.expectEqual(@as(u8, 3), table.next_index);
}

test "NameTable.add error NameTooLong" {
    var table = NameTable.init();

    const result = table.add("12345678"); // 8 chars, exceeds max
    try std.testing.expectError(error.NameTooLong, result);
}

test "NameTable.get returns correct name" {
    var table = NameTable.init();

    _ = try table.add("mysvc");
    const name = table.get(0);

    try std.testing.expectEqualStrings("mysvc", name);
}

test "NameTable.get returns empty for invalid index" {
    const table = NameTable.init();

    const name = table.get(99);
    try std.testing.expectEqualStrings("", name);
}

test "NameTable.find returns correct index" {
    var table = NameTable.init();

    _ = try table.add("svc1");
    _ = try table.add("svc2");

    const idx = table.find("svc2");
    try std.testing.expectEqual(@as(u8, 1), idx);
}

test "NameTable.find returns null for missing name" {
    var table = NameTable.init();

    _ = try table.add("svc1");

    const idx = table.find("missing");
    try std.testing.expectEqual(null, idx);
}

test "NameTable.isEmpty" {
    var table = NameTable.init();

    try std.testing.expect(table.isEmpty());

    _ = try table.add("test");
    try std.testing.expect(!table.isEmpty());
}

test "NameTable count" {
    var table = NameTable.init();

    _ = try table.add("a");
    _ = try table.add("b");

    try std.testing.expectEqual(@as(u8, 2), table.count());
}
