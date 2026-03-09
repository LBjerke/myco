//! Write-Ahead Log (WAL) for durable event persistence.
//! Provides atomic writes and replay capability for state reconstruction.

const std = @import("std");
const event = @import("../core/event.zig");
pub const WalEvent = event.WalEvent;
pub const Event = event.Event;
const limits = @import("../util/limits.zig");

/// Maximum events per segment file.
const MAX_EVENTS_PER_SEGMENT: usize = 1000;

/// Segment file header magic bytes.
const SEGMENT_MAGIC: [4]u8 = .{ 'M', 'Y', 'C', 'O' };
const SEGMENT_VERSION: u8 = 1;

/// WAL error types.
pub const WalError = error{
    IoError,
    ChecksumMismatch,
    InvalidSegment,
    SegmentFull,
    NoSegments,
};

/// Segment file metadata.
const SegmentHeader = struct {
    magic: [4]u8 = SEGMENT_MAGIC,
    version: u8 = SEGMENT_VERSION,
    event_count: u32 = 0,
    first_timestamp: u64 = 0,
    last_timestamp: u64 = 0,

    /// Serialize header to bytes.
    fn toBytes(header: SegmentHeader, out: []u8) void {
        @memcpy(out[0..4], &header.magic);
        out[4] = header.version;
        // Little-endian byte writes for integers
        out[5] = @truncate(header.event_count);
        out[6] = @truncate(header.event_count >> 8);
        out[7] = @truncate(header.event_count >> 16);
        out[8] = @truncate(header.event_count >> 24);
        // 8-byte timestamps
        out[9] = @truncate(header.first_timestamp);
        out[10] = @truncate(header.first_timestamp >> 8);
        out[11] = @truncate(header.first_timestamp >> 16);
        out[12] = @truncate(header.first_timestamp >> 24);
        out[13] = @truncate(header.first_timestamp >> 32);
        out[14] = @truncate(header.first_timestamp >> 40);
        out[15] = @truncate(header.first_timestamp >> 48);
        out[16] = @truncate(header.first_timestamp >> 56);
        out[17] = @truncate(header.last_timestamp);
        out[18] = @truncate(header.last_timestamp >> 8);
        out[19] = @truncate(header.last_timestamp >> 16);
        out[20] = @truncate(header.last_timestamp >> 24);
        out[21] = @truncate(header.last_timestamp >> 32);
        out[22] = @truncate(header.last_timestamp >> 40);
        out[23] = @truncate(header.last_timestamp >> 48);
        out[24] = @truncate(header.last_timestamp >> 56);
    }

    /// Deserialize header from bytes.
    fn fromBytes(bytes: [25]u8) SegmentHeader {
        var event_count: u32 = 0;
        event_count |= @as(u32, bytes[5]);
        event_count |= @as(u32, bytes[6]) << 8;
        event_count |= @as(u32, bytes[7]) << 16;
        event_count |= @as(u32, bytes[8]) << 24;

        var first_timestamp: u64 = 0;
        first_timestamp |= @as(u64, bytes[9]);
        first_timestamp |= @as(u64, bytes[10]) << 8;
        first_timestamp |= @as(u64, bytes[11]) << 16;
        first_timestamp |= @as(u64, bytes[12]) << 24;
        first_timestamp |= @as(u64, bytes[13]) << 32;
        first_timestamp |= @as(u64, bytes[14]) << 40;
        first_timestamp |= @as(u64, bytes[15]) << 48;
        first_timestamp |= @as(u64, bytes[16]) << 56;

        var last_timestamp: u64 = 0;
        last_timestamp |= @as(u64, bytes[17]);
        last_timestamp |= @as(u64, bytes[18]) << 8;
        last_timestamp |= @as(u64, bytes[19]) << 16;
        last_timestamp |= @as(u64, bytes[20]) << 24;
        last_timestamp |= @as(u64, bytes[21]) << 32;
        last_timestamp |= @as(u64, bytes[22]) << 40;
        last_timestamp |= @as(u64, bytes[23]) << 48;
        last_timestamp |= @as(u64, bytes[24]) << 56;

        return SegmentHeader{
            .magic = bytes[0..4].*,
            .version = bytes[4],
            .event_count = event_count,
            .first_timestamp = first_timestamp,
            .last_timestamp = last_timestamp,
        };
    }
};

/// In-memory segment state.
pub const Segment = struct {
    id: u32,
    file_path: []const u8,
    event_count: u32 = 0,
    first_timestamp: u64 = 0,
    last_timestamp: u64 = 0,
};

/// WAL state - holds in-memory state for zero-allocation runtime.
pub const Wal = struct {
    /// Directory path for WAL files.
    dir_path: []const u8,

    /// Current active segment.
    current_segment: Segment,

    /// Pre-allocated write buffer (used during init phase).
    write_buffer: []u8,

    /// Pre-allocated temp buffer for path formatting and reads.
    temp_buffer: [65536]u8 = undefined,

    /// Allocator for WAL operations (only valid during init phase).
    allocator: std.mem.Allocator,

    /// Buffer position.
    buffer_pos: usize = 0,

    /// File handle for current segment.
    file: ?std.fs.File = null,

    /// Whether WAL is initialized (for replay detection).
    initialized: bool = false,

    /// Initialize WAL with directory path and allocator.
    /// Must be called during init phase (before freeze).
    /// Note: All WAL operations (init, replay, append) must happen before allocator is frozen.
    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !Wal {
        // Create directory if it doesn't exist
        std.fs.cwd().makeDir(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Pre-allocate write buffer (64KB)
        const write_buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(write_buffer);

        // Find or create first segment
        var wal = Wal{
            .dir_path = dir_path,
            .current_segment = .{
                .id = 0,
                .file_path = undefined,
            },
            .write_buffer = write_buffer,
            .allocator = allocator,
        };

        try wal.openOrCreateSegment();

        return wal;
    }

    /// Open existing segment or create new one.
    fn openOrCreateSegment(self: *Wal) !void {
        const allocator = self.allocator;

        // Try to find existing segments
        var max_id: u32 = 0;
        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
                const id = std.fmt.parseInt(u32, entry.path[8..], 10) catch continue;
                if (id > max_id) max_id = id;
            }
        }

        // Use temp buffer for path formatting
        var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
        try path_fbs.writer().print("{s}/segment-{:0>4}", .{ self.dir_path, max_id });
        const segment_path = path_fbs.getWritten();

        // Copy to allocated memory (owned by Wal)
        const path_copy = try allocator.alloc(u8, segment_path.len);
        @memcpy(path_copy, segment_path);

        self.current_segment.file_path = path_copy;

        self.file = try std.fs.cwd().createFile(path_copy, .{ .read = true });
        const header: SegmentHeader = .{};
        var header_bytes: [25]u8 = undefined;
        header.toBytes(&header_bytes);
        _ = try self.file.?.write(&header_bytes);
    }

        // Free file path if allocated
        if (self.current_segment.file_path.len != 0) {
            self.allocator.free(self.current_segment.file_path);
            self.current_segment.file_path = &[_]u8{};
        }

        // Close file if open
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }

    /// Open existing segment or create new one.
    fn openOrCreateSegment(self: *Wal) !void {
        const allocator = self.allocator;

        // Try to find existing segments
        var max_id: u32 = 0;
        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
                const id = std.fmt.parseInt(u32, entry.path[8..], 10) catch continue;
                if (id > max_id) max_id = id;
            }
        }

        const segment_id = max_id;
        // Use temp buffer for path formatting
        var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
        try path_fbs.writer().print("{s}/segment-{:0>4}", .{ self.dir_path, segment_id });
        const segment_path = path_fbs.getWritten();

        // Copy to allocated memory (owned by Wal)
        const path_copy = try allocator.alloc(u8, segment_path.len);
        @memcpy(path_copy, segment_path);

        self.current_segment = .{
            .id = segment_id,
            .file_path = path_copy,
        };

        // Open or create file
        self.file = try std.fs.cwd().createFile(
            self.current_segment.file_path,
            .{ .truncate = false, .read = true },
        );

        // If new file, write header
        const stat_info = try self.file.?.stat();
        if (stat_info.size == 0) {
            const header: SegmentHeader = .{};
            var header_bytes: [25]u8 = undefined;
            header.toBytes(&header_bytes);
            _ = try self.file.?.write(&header_bytes);
            self.current_segment.event_count = 0;
        } else {
            // Read header to get event count
            var header_bytes: [25]u8 = undefined;
            _ = try self.file.?.read(&header_bytes);
            const header = SegmentHeader.fromBytes(header_bytes);
            self.current_segment.event_count = header.event_count;
            self.current_segment.first_timestamp = header.first_timestamp;
            self.current_segment.last_timestamp = header.last_timestamp;
        }
    }

    /// Append event to WAL with atomic write.
    /// Note: This function must be called during init phase (before allocator is frozen).
    pub fn append(self: *Wal, wal_event: WalEvent) !void {
        const allocator = self.allocator;

        // Serialize event to buffer
        var fbs = std.io.fixedBufferStream(self.write_buffer);
        try wal_event.serialize(fbs.writer());
        const event_data = self.write_buffer[0..fbs.pos];

        // Write to temp file first (atomic write) - use temp buffer for path
        var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
        try path_fbs.writer().print("{s}/.tmp-{:0>4}", .{ self.dir_path, self.current_segment.id });
        const temp_path = path_fbs.getWritten();

        // Need temporary memory for the path string (owned)
        const temp_pathOwned = try allocator.alloc(u8, temp_path.len);
        defer allocator.free(temp_pathOwned);
        @memcpy(temp_pathOwned, temp_path);

        var temp_file = try std.fs.cwd().createFile(temp_pathOwned, .{ .truncate = true });
        defer temp_file.close();

        // Copy existing segment data if any - use temp buffer
        if (self.current_segment.event_count > 0) {
            const estimated_size = 25 + self.current_segment.event_count * 50;
            // Use slice of temp buffer
            const read_buffer = self.temp_buffer[0..@min(estimated_size, self.temp_buffer.len)];
            const bytes_read = try self.file.?.read(read_buffer);
            try temp_file.writeAll(read_buffer[0..bytes_read]);
        }

        // Append new event
        try temp_file.writeAll(event_data);

        // Sync to disk
        try temp_file.sync();

        // Close original
        if (self.file) |f| f.close();

        // Atomic rename
        try std.fs.cwd().rename(temp_pathOwned, self.current_segment.file_path);

        // Reopen file
        self.file = try std.fs.cwd().openFile(self.current_segment.file_path, .{ .mode = .read_write });

        // Update segment metadata
        self.current_segment.event_count += 1;
        if (self.current_segment.first_timestamp == 0) {
            self.current_segment.first_timestamp = wal_event.event.getTimestamp().time;
        }
        self.current_segment.last_timestamp = wal_event.event.getTimestamp().time;

        // Update header
        try self.file.?.seekTo(0);
        const header: SegmentHeader = .{
            .event_count = self.current_segment.event_count,
            .first_timestamp = self.current_segment.first_timestamp,
            .last_timestamp = self.current_segment.last_timestamp,
        };
        var header_bytes: [25]u8 = undefined;
        header.toBytes(&header_bytes);
        _ = try self.file.?.write(&header_bytes);

        // Check if we need a new segment
        if (self.current_segment.event_count >= MAX_EVENTS_PER_SEGMENT) {
            try self.rotateSegment();
        }
    }

    /// Rotate to a new segment file.
    fn rotateSegment(self: *Wal) !void {
        const allocator = self.allocator;

        if (self.file) |f| f.close();
        self.file = null;

        self.current_segment.id += 1;
        self.current_segment.event_count = 0;
        self.current_segment.first_timestamp = 0;
        self.current_segment.last_timestamp = 0;

        // Use temp buffer for path formatting
        var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
        try path_fbs.writer().print("{s}/segment-{:0>4}", .{ self.dir_path, self.current_segment.id });
        const segment_path = path_fbs.getWritten();

        // Copy to allocated memory (owned by Wal)
        const path_copy = try allocator.alloc(u8, segment_path.len);
        @memcpy(path_copy, segment_path);

        self.current_segment.file_path = path_copy;

        self.file = try std.fs.cwd().createFile(path_copy, .{ .read = true });
        const header: SegmentHeader = .{};
        var header_bytes: [25]u8 = undefined;
        header.toBytes(&header_bytes);
        _ = try self.file.?.write(&header_bytes);
    }

    /// Replay events from WAL to reconstruct state.
    /// Callback is called for each event.
    pub fn replay(self: *Wal, ctx: anytype, applyFn: fn (@TypeOf(ctx), Event) void) !void {
        const allocator = self.allocator;

        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        // Collect all segment files - use fixed array for simplicity
        var segments: [100]u32 = undefined;
        var segment_count: usize = 0;

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
                const id = std.fmt.parseInt(u32, entry.path[8..], 10) catch continue;
                if (segment_count < segments.len) {
                    segments[segment_count] = id;
                    segment_count += 1;
                }
            }
        }

        // Note: walker iterates in sorted order, no explicit sort needed

        // Replay each segment in order
        for (segments[0..segment_count]) |segment_id| {
            // Use temp buffer for path formatting
            var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
            try path_fbs.writer().print("{s}/segment-{:0>4}", .{ self.dir_path, segment_id });
            const segment_path = path_fbs.getWritten();

            // Copy to temporary allocated memory
            const path_copy = try allocator.alloc(u8, segment_path.len);
            defer allocator.free(path_copy);
            @memcpy(path_copy, segment_path);

            var file = try std.fs.cwd().openFile(path_copy, .{ .mode = .read_only });
            defer file.close();

            // Read header
            var header_bytes: [25]u8 = undefined;
            _ = try file.read(&header_bytes);
            const header = SegmentHeader.fromBytes(header_bytes);

            // Validate header
            if (!std.mem.eql(u8, &header.magic, &SEGMENT_MAGIC)) {
                return WalError.InvalidSegment;
            }

            // Read and apply each event - use temp buffer
            const stat = try file.stat();
            const buffer_size = @min(@as(usize, stat.size), self.temp_buffer.len);
            const buffer = self.temp_buffer[0..buffer_size];
            _ = try file.read(buffer);

            // Skip header
            var pos: usize = 25;

            // Read events from buffer
            var local_count: u32 = 0;
            while (local_count < header.event_count and pos < buffer.len) {
                // Create a reader from the current position
                const event_buffer = buffer[pos..];
                var fbs = std.io.fixedBufferStream(event_buffer);

                // Deserialize the WalEvent (includes checksum)
                const wal_event = try WalEvent.deserialize(fbs.reader());

                // Advance position by the bytes consumed
                pos += fbs.pos;

                local_count += 1;

                // Pass the properly deserialized event to applyFn
                applyFn(ctx, wal_event.event);
            }
        }
    }

    /// Get current segment info.
    pub fn getSegmentInfo(self: *Wal) Segment {
        return self.current_segment;
    }

    /// Get total event count across all segments.
    pub fn getTotalEventCount(self: *Wal) !u64 {
        const allocator = self.allocator;

        var total: u64 = 0;
        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, "segment-")) {
                // Use temp buffer for path
                var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
                path_fbs.writer().print("{s}/{s}", .{ self.dir_path, entry.path }) catch continue;
                const segment_path = path_fbs.getWritten();

                // Copy to temporary allocated memory
                const path_copy = allocator.alloc(u8, segment_path.len) catch continue;
                defer allocator.free(path_copy);
                @memcpy(path_copy, segment_path);

                var file = try std.fs.cwd().openFile(path_copy, .{ .mode = .read_only });
                defer file.close();

                var header_bytes: [25]u8 = undefined;
                _ = try file.read(&header_bytes);
                const header = SegmentHeader.fromBytes(header_bytes);
                total += header.event_count;
            }
        }

        return total;
    }

    /// Close WAL and free resources.
    pub fn deinit(self: *Wal) void {
        // Close file if open
        if (self.file) |f| {
            f.close();
            self.file = null;
        }

        // Free write buffer
        if (self.write_buffer.len > 0) {
            self.allocator.free(self.write_buffer);
            self.write_buffer = &[_]u8{};
        }

        // Free file path if allocated
        if (self.current_segment.file_path.len != 0) {
            self.allocator.free(self.current_segment.file_path);
            self.current_segment.file_path = &[_]u8{};
        }
    }
};

/// Create a node join event helper.
pub fn makeNodeJoinEvent(node_id: u16, address: [4]u8, port: u16) Event {
    return .{
        .node_join = .{
            .node_id = node_id,
            .address = address,
            .port = port,
            .timestamp = .{ .time = @intCast(std.time.milliTimestamp()), .count = 0, .node_id = 0 },
        },
    };
}

/// Create a service deploy event helper.
pub fn makeServiceDeployEvent(service_id: u16, name: []const u8, replicas: u8) !Event {
    var name_buffer: [32]u8 = undefined;
    @memcpy(name_buffer[0..name.len], name);

    return .{
        .service_deploy = .{
            .service_id = service_id,
            .name = name_buffer,
            .name_len = @truncate(name.len),
            .replicas = replicas,
            .timestamp = .{ .time = @intCast(std.time.milliTimestamp()), .count = 0, .node_id = 0 },
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Wal.init creates directory" {
    const test_dir = "test-wal-tmp";
    defer {
        std.fs.cwd().deleteTree(test_dir) catch {};
    }

    const allocator = std.testing.allocator;
    var wal = try Wal.init(allocator, test_dir);
    defer wal.deinit();

    try std.testing.expect(wal.initialized == false);
    try std.testing.expect(wal.current_segment.event_count == 0);
}

test "Wal.append writes event" {
    const test_dir = "test-wal-append";
    defer {
        std.fs.cwd().deleteTree(test_dir) catch {};
    }

    const allocator = std.testing.allocator;
    var wal = try Wal.init(allocator, test_dir);
    defer wal.deinit();

    const node_event = makeNodeJoinEvent(1, .{ 127, 0, 0, 1 }, 8080);
    const wal_event = WalEvent.create(node_event);

    try wal.append(wal_event);

    try std.testing.expect(wal.current_segment.event_count == 1);
}

test "Wal.getTotalEventCount returns correct count" {
    const test_dir = "test-wal-count";
    defer {
        std.fs.cwd().deleteTree(test_dir) catch {};
    }

    const allocator = std.testing.allocator;
    var wal = try Wal.init(allocator, test_dir);
    defer wal.deinit();

    const node_event = makeNodeJoinEvent(1, .{ 127, 0, 0, 1 }, 8080);
    const wal_event = WalEvent.create(node_event);

    try wal.append(wal_event);
    try wal.append(wal_event);
    try wal.append(wal_event);

    const total = try wal.getTotalEventCount();
    try std.testing.expectEqual(@as(u64, 3), total);
}

test "Wal.replay applies events" {
    const test_dir = "test-wal-replay";
    defer {
        std.fs.cwd().deleteTree(test_dir) catch {};
    }

    const allocator = std.testing.allocator;
    var wal = try Wal.init(allocator, test_dir);
    defer wal.deinit();

    // Write some events
    const event1 = makeNodeJoinEvent(1, .{ 127, 0, 0, 1 }, 8080);
    const event2 = makeServiceDeployEvent(1, "test-svc", 3) catch unreachable;

    try wal.append(WalEvent.create(event1));
    try wal.append(WalEvent.create(event2));

    // Replay and collect
    var count: usize = 0;
    try wal.replay(&count, struct {
        fn apply(c: *usize, e: Event) void {
            _ = e;
            c.* += 1;
        }
    }.apply);

    try std.testing.expectEqual(@as(usize, 2), count);
}
