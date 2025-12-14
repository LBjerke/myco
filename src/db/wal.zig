const std = @import("std");

/// A single entry in the Write-Ahead Log.
pub const Entry = extern struct {
    /// Checksum of the data to detect corruption.
    crc: u32 = 0,
    /// The actual data (in our case, the 'Knowledge' u64).
    value: u64 = 0,
};

/// The Write-Ahead Log Manager.
/// Simulates an append-only file on disk.
pub const WriteAheadLog = struct {
    /// The "Disk" buffer.
    buffer: []u8,
    /// Current write head position.
    cursor: usize = 0,

    pub fn init(buffer: []u8) WriteAheadLog {
        return .{ .buffer = buffer };
    }

    /// Append a new state value to the log.
    pub fn append(self: *WriteAheadLog, value: u64) !void {
        if (self.cursor + @sizeOf(Entry) > self.buffer.len) {
            return error.DiskFull;
        }

        var entry = Entry{ .value = value };
        // Calculate CRC32 of the value bytes
        const value_bytes = std.mem.asBytes(&entry.value);
        entry.crc = std.hash.Crc32.hash(value_bytes);

        // "Write to Disk" (Copy to buffer)
        const entry_bytes = std.mem.asBytes(&entry);
        @memcpy(self.buffer[self.cursor..][0..@sizeOf(Entry)], entry_bytes);
        
        self.cursor += @sizeOf(Entry);
    }

    /// Replay the log to find the latest valid state.
    /// Returns 0 if log is empty or corrupted.
    pub fn recover(self: *WriteAheadLog) u64 {
        var pos: usize = 0;
        var latest_value: u64 = 0;

        // Iterate through the buffer reading entries
        while (pos + @sizeOf(Entry) <= self.buffer.len) {
            // Read entry
            const entry_bytes = self.buffer[pos..][0..@sizeOf(Entry)];
            const entry: *const Entry = @ptrCast(@alignCast(entry_bytes));

            // Stop if we hit empty space (assuming 0-init disk)
            if (entry.crc == 0 and entry.value == 0) break;

            // VERIFY CHECKSUM
            const value_bytes = std.mem.asBytes(&entry.value);
            const expected_crc = std.hash.Crc32.hash(value_bytes);

            if (entry.crc != expected_crc) {
                // Corruption detected! Stop replay.
                // In production, we might truncate here.
                std.debug.print("[WAL] Corruption at offset {d}\n", .{pos});
                break;
            }

            // Valid entry found
            latest_value = entry.value;
            pos += @sizeOf(Entry);
        }

        // Restore the cursor to the end of valid data
        self.cursor = pos;
        return latest_value;
    }
};
