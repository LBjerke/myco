// Minimal write-ahead log abstraction over an in-memory buffer for durability simulation.
// This file implements a minimal Write-Ahead Log (WAL) abstraction,
// primarily designed for durability simulation within the Myco system.
// It allows for appending new state values (represented by `Entry` structs,
// each with a CRC checksum) to an in-memory buffer. The module also provides
// functionality to recover the latest valid state by replaying the log and
// detecting any data corruption. This is crucial for ensuring data integrity
// and system recovery from unexpected failures.
//
const std = @import("std");

/// A single entry in the Write-Ahead Log.
/// On-disk WAL entry for a single knowledge value.
pub const Entry = extern struct {
    /// Checksum of the data to detect corruption.
    crc: u32 = 0,
    /// The actual data (in our case, CRDT Entry: id, version).
    id: u64 = 0,
    version: u64 = 0,
};

pub const SNAPSHOT_MAGIC: u32 = 0x4D59534E; // MYSN (Myco Snap)

/// Header for the snapshot buffer.
pub const SnapshotHeader = extern struct {
    magic: u32,
    data_len: u32,
    crc: u32,
};

/// The Write-Ahead Log Manager.
/// Simulates an append-only file on disk.
/// Append-only WAL that can recover the latest valid knowledge value.
pub const WriteAheadLog = struct {
    /// The buffer for log entries.
    log_buffer: []u8,
    /// The buffer for snapshot data.
    snap_buffer: []u8,
    /// Current write head position in the log buffer.
    log_cursor: usize = 0,

    /// Initialize a WAL over the provided log and snapshot buffers.
    pub fn init(log_buffer: []u8, snap_buffer: []u8) WriteAheadLog {
        return .{
            .log_buffer = log_buffer,
            .snap_buffer = snap_buffer,
        };
    }

    /// Append a new state value to the log.
    pub fn append(self: *WriteAheadLog, id: u64, version: u64) !void {
        if (self.log_cursor + @sizeOf(Entry) > self.log_buffer.len) {
            return error.DiskFull;
        }

        var entry = Entry{ .id = id, .version = version };
        // Calculate CRC32 of the id+version bytes
        const data_bytes = std.mem.asBytes(&entry.id)[0..] ++ std.mem.asBytes(&entry.version)[0..];
        entry.crc = std.hash.Crc32.hash(data_bytes);

        // "Write to Disk" (Copy to log_buffer)
        const entry_bytes = std.mem.asBytes(&entry);
        @memcpy(self.log_buffer[self.log_cursor..][0..@sizeOf(Entry)], entry_bytes);

        self.log_cursor += @sizeOf(Entry);
    }

    /// Write a snapshot to the snapshot buffer and truncate the log.
    pub fn compact(self: *WriteAheadLog, snapshot_data: []const u8) !void {
        if (snapshot_data.len + @sizeOf(SnapshotHeader) > self.snap_buffer.len) {
            return error.DiskFull; // Or specific error like SnapshotBufferFull
        }

        var header = SnapshotHeader{ .magic = SNAPSHOT_MAGIC, .data_len = @intCast(snapshot_data.len), .crc = std.hash.Crc32.hash(snapshot_data) };

        const header_bytes = std.mem.asBytes(&header);
        @memcpy(self.snap_buffer[0..@sizeOf(SnapshotHeader)], header_bytes);
        @memcpy(self.snap_buffer[@sizeOf(SnapshotHeader) .. @sizeOf(SnapshotHeader) + snapshot_data.len], snapshot_data);

        // Atomically update header after data is written (simulated by overwriting)
        // For simulation, just assume it's atomic.

        // Truncate log
        self.log_cursor = 0;
    }

    /// Replay the log to find the latest valid state.
    /// Returns 0 if log is empty or corrupted.
    /// Replay the log and return the most recent non-corrupt value.
    pub fn recover(self: *WriteAheadLog, ctx: *anyopaque, load_log_entry_fn: *const fn (ctx: *anyopaque, id: u64, ver: u64) void, load_snapshot_fn: *const fn (ctx: *anyopaque, data: []const u8) void) !void {
        // 1. Recover Snapshot
        if (self.snap_buffer.len >= @sizeOf(SnapshotHeader)) {
            const header_bytes = self.snap_buffer[0..@sizeOf(SnapshotHeader)];
            const header = std.mem.bytesToValue(SnapshotHeader, header_bytes);

            if (header.magic == SNAPSHOT_MAGIC and header.data_len > 0 and header.data_len <= self.snap_buffer.len - @sizeOf(SnapshotHeader)) {
                const snapshot_data = self.snap_buffer[@sizeOf(SnapshotHeader) .. @sizeOf(SnapshotHeader) + header.data_len];
                const expected_crc = std.hash.Crc32.hash(snapshot_data);
                if (header.crc == expected_crc) {
                    load_snapshot_fn(ctx, snapshot_data);
                } else {
                    std.debug.print("[WAL] Snapshot corruption detected (bad CRC).\n", .{});
                }
            }
        }

        // 2. Replay Log
        var pos: usize = 0;
        self.log_cursor = 0; // Reset to recalculate valid log length

        while (pos + @sizeOf(Entry) <= self.log_buffer.len) {
            // Read entry
            const entry_bytes = self.log_buffer[pos..][0..@sizeOf(Entry)];
            const entry = std.mem.bytesToValue(Entry, entry_bytes);

            // Stop if we hit empty space (assuming 0-init disk)
            if (entry.crc == 0 and entry.id == 0 and entry.version == 0) break;

            // VERIFY CHECKSUM
            const data_bytes = std.mem.asBytes(&entry.id)[0..] ++ std.mem.asBytes(&entry.version)[0..];
            const expected_crc = std.hash.Crc32.hash(data_bytes);

            if (entry.crc != expected_crc) {
                // Corruption detected! Stop replay.
                std.debug.print("[WAL] Log corruption at offset {d}\n", .{pos});
                break;
            }

            // Valid entry found
            load_log_entry_fn(ctx, entry.id, entry.version);
            pos += @sizeOf(Entry);
        }

        // Restore the cursor to the end of valid data
        self.log_cursor = pos;
    }
};

test "WriteAheadLog: append, recover, and stop on corruption" {
    var log_disk = [_]u8{0} ** (@sizeOf(Entry) * 4);
    var snap_disk = [_]u8{0} ** 256; // Smaller snapshot buffer for test

    var wal = WriteAheadLog.init(&log_disk, &snap_disk);

    // Mock functions for recovery
    var recovered_map = std.AutoHashMap(u64, u64).init(std.testing.allocator);
    defer recovered_map.deinit();

    const Context = struct {
        map: *std.AutoHashMap(u64, u64),
    };
    var ctx = Context{ .map = &recovered_map };

    const loader = struct {
        fn load_log_entry(c: *Context, id: u64, ver: u64) void {
            c.map.put(id, ver) catch unreachable;
        }
        fn load_snapshot(c: *Context, data: []const u8) void {
            // For this test, snapshot data is just id, version pairs
            var fbs = std.io.fixedBufferStream(data);
            var reader = fbs.reader();
            while (true) {
                const id = reader.readInt(u64, .little) catch break;
                const ver = reader.readInt(u64, .little) catch break;
                c.map.put(id, ver) catch unreachable;
            }
        }
    };

    // Test 1: Simple append and recovery
    try wal.append(1, 100);
    try wal.append(2, 200);

    recovered_map.clearAndFree();
    try wal.recover(&ctx, loader.load_log_entry, loader.load_snapshot);
    try std.testing.expectEqual(@as(u64, 100), recovered_map.get(1).?);
    try std.testing.expectEqual(@as(u64, 200), recovered_map.get(2).?);
    try std.testing.expectEqual(@as(usize, 2), recovered_map.count());

    // Test 2: Corruption in log
    const corrupt_offset = @sizeOf(Entry) * 1;
    log_disk[corrupt_offset] ^= 0xFF; // Corrupt the second entry

    recovered_map.clearAndFree();
    try wal.recover(&ctx, loader.load_log_entry, loader.load_snapshot);
    try std.testing.expectEqual(@as(u64, 100), recovered_map.get(1).?);
    try std.testing.expectEqual(@as(usize, 1), recovered_map.count()); // Only first entry recovered
    log_disk[corrupt_offset] ^= 0xFF; // Restore for next tests.

    // Test 3: Snapshot and log combined
    recovered_map.clearAndFree();
    try wal.append(4, 400); // Now log has 1,2,4 (2 is corrupt)

    // Create snapshot data from current state (simulated)
    var current_state_snap = std.ArrayList(u8).init(std.testing.allocator);
    defer current_state_snap.deinit();
    try current_state_snap.writer().writeInt(u64, 1, .little);
    try current_state_snap.writer().writeInt(u64, 100, .little);
    try current_state_snap.writer().writeInt(u64, 4, .little);
    try current_state_snap.writer().writeInt(u64, 400, .little);

    try wal.compact(current_state_snap.items);

    // Append more to the (now truncated) log
    try wal.append(5, 500);

    recovered_map.clearAndFree();
    try wal.recover(&ctx, loader.load_log_entry, loader.load_snapshot);
    try std.testing.expectEqual(@as(u64, 100), recovered_map.get(1).?);
    try std.testing.expectEqual(@as(u64, 400), recovered_map.get(4).?);
    try std.testing.expectEqual(@as(u64, 500), recovered_map.get(5).?);
    try std.testing.expectEqual(@as(usize, 3), recovered_map.count());
}
