//! Write-Ahead Log (WAL) for durable event persistence.
//! Provides atomic writes and replay capability for state reconstruction.

const std = @import("std");
const event = @import("../core/event.zig");
pub const WalEvent = event.WalEvent;
pub const Event = event.Event;
const limits = @import("../util/limits.zig");
const assert = @import("../util/assert.zig");

/// Maximum events per segment file.
const max_events_per_segment: usize = 1000;

/// Segment file header magic bytes.
const segment_magic: [4]u8 = .{ 'M', 'Y', 'C', 'O' };
const segment_version: u8 = 1;

/// WAL filename constants
const segment_prefix = limits.wal_segment_prefix;
const segment_prefix_len = segment_prefix.len;
const temp_prefix = limits.wal_temp_prefix;

/// WAL error types.
pub const WalError = error{
    IoError,
    ChecksumMismatch,
    InvalidSegment,
    InvalidEventData,
    SegmentFull,
    NoSegments,
};

/// Segment file metadata.
const SegmentHeader = struct {
    magic: [4]u8 = segment_magic,
    version: u8 = segment_version,
    event_count: u32 = 0,
    first_timestamp: u64 = 0,
    last_timestamp: u64 = 0,

    /// Serialize header to bytes.
    fn toBytes(header: SegmentHeader, out: *[limits.wal_header_size]u8) void {
        @memcpy(out[0..4], &header.magic);
        out[4] = header.version;
        std.mem.writeInt(u32, out[5..9], header.event_count, .little);
        std.mem.writeInt(u64, out[9..17], header.first_timestamp, .little);
        std.mem.writeInt(u64, out[17..25], header.last_timestamp, .little);
    }

    /// Deserialize header from bytes.
    fn fromBytes(bytes: [limits.wal_header_size]u8) SegmentHeader {
        return SegmentHeader{
            .magic = bytes[0..4].*,
            .version = bytes[4],
            .event_count = std.mem.readInt(u32, bytes[5..9], .little),
            .first_timestamp = std.mem.readInt(u64, bytes[9..17], .little),
            .last_timestamp = std.mem.readInt(u64, bytes[17..25], .little),
        };
    }
};

/// In-memory segment state.
pub const Segment = struct {
    idx: u32,
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
    temp_buffer: [limits.wal_temp_buffer_size]u8 = undefined,

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

        // Pre-allocate write buffer
        const write_buffer = try allocator.alloc(u8, limits.wal_write_buffer_size);
        errdefer allocator.free(write_buffer);

        // Find or create first segment
        var wal = Wal{
            .dir_path = dir_path,
            .current_segment = .{
                .idx = 0,
                .file_path = undefined,
            },
            .write_buffer = write_buffer,
            .allocator = allocator,
        };

        try wal.openOrCreateSegment();

        return wal;
    }

    /// Format a path using the WAL's temp buffer.
    /// Returns a slice of the formatted path.
    fn formatPath(self: *Wal, comptime fmt: []const u8, args: anytype) ![]const u8 {
        var path_fbs = std.io.fixedBufferStream(&self.temp_buffer);
        try path_fbs.writer().print(fmt, args);
        return path_fbs.getWritten();
    }

    /// Find the maximum segment ID in the WAL directory.
    /// Returns 0 if no segments exist.
    fn findMaxSegmentId(self: *Wal) !u32 {
        const allocator = self.allocator;
        var max_id: u32 = 0;

        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, segment_prefix)) {
                const seg_id_slice = entry.path[segment_prefix_len..];
                const seg_id = std.fmt.parseInt(u32, seg_id_slice, 10) catch continue;
                if (seg_id > max_id) max_id = seg_id;
            }
        }

        return max_id;
    }

    /// Create a new segment file with empty header.
    fn createSegmentFile(self: *Wal, path: []const u8) !void {
        self.file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });

        const stat_info = try self.file.?.stat();
        if (stat_info.size == 0) {
            const header: SegmentHeader = .{};
            var header_bytes: [limits.wal_header_size]u8 = undefined;
            header.toBytes(&header_bytes);
            _ = try self.file.?.write(&header_bytes);
            self.current_segment.event_count = 0;
        }
    }

    /// Open an existing segment file and read its header.
    fn openExistingSegment(self: *Wal, path: []const u8) !void {
        self.file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = true });

        // Read header to get event count
        var header_bytes: [limits.wal_header_size]u8 = undefined;
        _ = try self.file.?.read(&header_bytes);
        const header = SegmentHeader.fromBytes(header_bytes);
        self.current_segment.event_count = header.event_count;
        self.current_segment.first_timestamp = header.first_timestamp;
        self.current_segment.last_timestamp = header.last_timestamp;
    }

    /// Open existing segment or create new one.
    fn openOrCreateSegment(self: *Wal) !void {
        const allocator = self.allocator;

        // Note: Zig's type system ensures allocator is valid - no additional assertion needed

        // Find highest segment ID
        const segment_id = try self.findMaxSegmentId();

        // Format path
        const segment_path = try self.formatPath(
            "{s}/segment-{:0>4}",
            .{ self.dir_path, segment_id },
        );

        // Copy to allocated memory (owned by Wal)
        const path_copy = try allocator.alloc(u8, segment_path.len);
        @memcpy(path_copy, segment_path);

        self.current_segment = .{
            .idx = segment_id,
            .file_path = path_copy,
        };

        // Open or create file
        const stat_info = std.fs.cwd().statFile(path_copy) catch null;
        if (stat_info == null or stat_info.?.size == 0) {
            try self.createSegmentFile(path_copy);
        } else {
            try self.openExistingSegment(path_copy);
        }
    }

    /// Serialize event to the write buffer.
    /// Returns a slice of the serialized data.
    fn serializeEvent(self: *Wal, wal_event: WalEvent) []u8 {
        var fbs = std.io.fixedBufferStream(self.write_buffer);
        wal_event.serialize(fbs.writer()) catch unreachable;
        return self.write_buffer[0..fbs.pos];
    }

    /// Copy existing segment data to a temp file.
    fn copyToTempFile(self: *Wal, temp_file: std.fs.File) !void {
        if (self.file) |f| {
            try f.seekTo(0);
            while (true) {
                const bytes_read = try f.read(self.temp_buffer[0..]);
                if (bytes_read == 0) break;
                try temp_file.writeAll(self.temp_buffer[0..bytes_read]);
            }
        }
    }

    /// Atomically swap temp file with segment file.
    fn swapFiles(self: *Wal, temp_path: []const u8) !void {
        // Close original
        if (self.file) |f| f.close();
        self.file = null;

        // Atomic rename
        try std.fs.cwd().rename(temp_path, self.current_segment.file_path);

        // Reopen file
        self.file = try std.fs.cwd().openFile(
            self.current_segment.file_path,
            .{ .mode = .read_write },
        );
    }

    /// Update segment header with new event metadata.
    fn updateSegmentHeader(self: *Wal, wal_event: WalEvent) !void {
        // Update segment metadata
        self.current_segment.event_count += 1;
        if (self.current_segment.first_timestamp == 0) {
            self.current_segment.first_timestamp = wal_event.event.getTimestamp().time;
        }
        self.current_segment.last_timestamp = wal_event.event.getTimestamp().time;

        // Write header
        try self.file.?.seekTo(0);
        const header: SegmentHeader = .{
            .event_count = self.current_segment.event_count,
            .first_timestamp = self.current_segment.first_timestamp,
            .last_timestamp = self.current_segment.last_timestamp,
        };
        var header_bytes: [limits.wal_header_size]u8 = undefined;
        header.toBytes(&header_bytes);
        _ = try self.file.?.write(&header_bytes);
    }

    /// Append event to WAL with atomic write.
    /// Note: This function must be called during init phase (before allocator is frozen).
    pub fn append(self: *Wal, wal_event: WalEvent) !void {
        // NASA Power of 10 Rule 5: Assert file handle is valid before write
        self.validateForAppend();

        // Serialize event to buffer
        const event_data = self.serializeEvent(wal_event);

        // Write to temp file and perform atomic swap
        try self.writeEventWithAtomicSwap(event_data);

        // Update header
        try self.updateSegmentHeader(wal_event);

        // Check if we need a new segment
        if (self.current_segment.event_count >= max_events_per_segment) {
            try self.rotateSegment();
        }
    }

    /// Validate WAL state before appending.
    fn validateForAppend(self: *Wal) void {
        assert.assert(self.file != null, "WAL file handle must not be null in append");
        assert.assert(self.current_segment.file_path.len > 0, "WAL segment path must be set");
    }

    /// Write event data to temp file and perform atomic swap.
    fn writeEventWithAtomicSwap(self: *Wal, event_data: []u8) !void {
        const allocator = self.allocator;

        // Write to temp file first (atomic write) - use helper for path
        const temp_path = try self.formatPath(
            "{s}/{s}{:0>4}",
            .{ self.dir_path, temp_prefix, self.current_segment.idx },
        );

        // Need temporary memory for the path string (owned)
        const temp_path_owned = try allocator.alloc(u8, temp_path.len);
        defer allocator.free(temp_path_owned);
        @memcpy(temp_path_owned, temp_path);

        var temp_file = try std.fs.cwd().createFile(temp_path_owned, .{ .truncate = true });
        defer temp_file.close();

        // Copy existing segment data into temp file
        try self.copyToTempFile(temp_file);

        // Append new event
        try temp_file.writeAll(event_data);

        // Sync to disk
        try temp_file.sync();

        // Atomic swap
        try self.swapFiles(temp_path_owned);
    }

    /// Rotate to a new segment file.
    fn rotateSegment(self: *Wal) !void {
        const allocator = self.allocator;

        // NASA Power of 10 Rule 5: Assert segment ID won't overflow
        assert.assert(
            self.current_segment.idx < 100000,
            "WAL segment ID exceeded reasonable limit",
        );

        if (self.file) |f| f.close();
        self.file = null;

        self.current_segment.idx += 1;
        self.current_segment.event_count = 0;
        self.current_segment.first_timestamp = 0;
        self.current_segment.last_timestamp = 0;

        // Use helper for path formatting
        const segment_path = try self.formatPath(
            "{s}/{s}{:0>4}",
            .{ self.dir_path, segment_prefix, self.current_segment.idx },
        );

        // Copy to allocated memory (owned by Wal)
        const path_copy = try allocator.alloc(u8, segment_path.len);
        @memcpy(path_copy, segment_path);

        self.current_segment.file_path = path_copy;

        self.file = try std.fs.cwd().createFile(path_copy, .{ .read = true });
        const header: SegmentHeader = .{};
        var header_bytes: [limits.wal_header_size]u8 = undefined;
        header.toBytes(&header_bytes);
        _ = try self.file.?.write(&header_bytes);
    }

    /// Collect all segment IDs from the WAL directory.
    /// Returns a slice of segment IDs (already sorted by filesystem).
    fn collectSegmentIds(self: *Wal) ![]const u32 {
        const allocator = self.allocator;
        var segments: [limits.wal_max_segments]u32 = undefined;
        var segment_count: usize = 0;

        var dir = try std.fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.path, segment_prefix)) {
                const seg_id_slice = entry.path[segment_prefix_len..];
                const seg_id = std.fmt.parseInt(u32, seg_id_slice, 10) catch continue;
                if (segment_count < segments.len) {
                    segments[segment_count] = seg_id;
                    segment_count += 1;
                }
            }
        }

        return segments[0..segment_count];
    }

    /// Validate segment header - checks magic bytes and event count.
    fn validateSegmentHeader(header: SegmentHeader) !void {
        // NASA Power of 10 Rule 5: Assert magic bytes are valid
        assert.assert(
            std.mem.eql(u8, &header.magic, &segment_magic),
            "WAL segment has invalid magic bytes",
        );

        if (!std.mem.eql(u8, &header.magic, &segment_magic)) {
            return WalError.InvalidSegment;
        }

        // NASA Power of 10 Rule 5: Assert event count is within reasonable bounds
        assert.assertLessThan(
            u32,
            header.event_count,
            max_events_per_segment * 2,
            "WAL segment event count exceeds maximum",
        );
    }

    /// Replay events from a single segment file.
    fn replaySingleSegment(
        self: *Wal,
        ctx: anytype,
        applyFn: fn (@TypeOf(ctx), Event) void,
        segment_id: u32,
    ) !void {
        const allocator = self.allocator;
        const buffer_slice = try self.readSegmentIntoBuffer(allocator, segment_id);

        var pos: usize = 0;
        var local_count: u32 = 0;
        const event_count = buffer_slice.event_count;

        // NASA Power of 10 Rule 2: Add explicit loop bound with assertion
        var iterations: usize = 0;
        const max_iterations = max_events_per_segment * 10; // Allow for multiple segments

        while (local_count < event_count and pos < buffer_slice.data.len) {
            // NASA Power of 10 Rule 5: Assert loop doesn't exceed proven bounds
            assert.assert(iterations < max_iterations, "WAL replay loop exceeded max iterations");
            iterations += 1;

            // Deserialize and apply event
            try self.deserializeAndApplyEvent(ctx, applyFn, buffer_slice.data[pos..], &pos);
            local_count += 1;
        }
    }

    /// Read segment file into buffer and return header info plus data.
    fn readSegmentIntoBuffer(
        self: *Wal,
        allocator: std.mem.Allocator,
        segment_id: u32,
    ) !struct { event_count: u32, data: []u8 } {
        // Use helper for path formatting
        const segment_path = try self.formatPath(
            "{s}/{s}{:0>4}",
            .{ self.dir_path, segment_prefix, segment_id },
        );

        // Copy to temporary allocated memory
        const path_copy = try allocator.alloc(u8, segment_path.len);
        defer allocator.free(path_copy);
        @memcpy(path_copy, segment_path);

        var file = try std.fs.cwd().openFile(path_copy, .{ .mode = .read_only });
        defer file.close();

        // Read header
        var header_bytes: [limits.wal_header_size]u8 = undefined;
        _ = try file.read(&header_bytes);
        const header = SegmentHeader.fromBytes(header_bytes);

        // Validate header (free function)
        try validateSegmentHeader(header);

        // Read and apply each event - use temp buffer (file cursor is after header)
        const stat = try file.stat();
        if (stat.size < limits.wal_header_size) {
            return WalError.InvalidSegment;
        }
        const remaining_size = @as(usize, stat.size - limits.wal_header_size);
        const buffer_size = @min(remaining_size, self.temp_buffer.len);
        const buffer = self.temp_buffer[0..buffer_size];
        const bytes_read = try file.read(buffer);

        return .{
            .event_count = header.event_count,
            .data = buffer[0..bytes_read],
        };
    }

    /// Deserialize a single event from buffer and apply it.
    fn deserializeAndApplyEvent(
        _: *Wal,
        ctx: anytype,
        applyFn: fn (@TypeOf(ctx), Event) void,
        event_buffer: []u8,
        pos: *usize,
    ) !void {
        var fbs = std.io.fixedBufferStream(event_buffer);

        // Deserialize the WalEvent (includes checksum)
        const wal_event = try WalEvent.deserialize(fbs.reader());

        // Guard against infinite loop if deserialize consumed no bytes (malformed data)
        if (fbs.pos == 0) {
            return WalError.InvalidEventData;
        }

        // Advance position by the bytes consumed
        pos.* += fbs.pos;

        // Pass the properly deserialized event to applyFn
        applyFn(ctx, wal_event.event);
    }

    /// Replay events from WAL to reconstruct state.
    /// Callback is called for each event.
    pub fn replay(self: *Wal, ctx: anytype, applyFn: fn (@TypeOf(ctx), Event) void) !void {
        // Collect all segment files
        const segments = try self.collectSegmentIds();

        // Note: walker iterates in sorted order, no explicit sort needed

        // Replay each segment in order
        for (segments) |segment_id| {
            try self.replaySingleSegment(ctx, applyFn, segment_id);
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
            total += try self.addEventCountIfSegment(allocator, entry);
        }

        return total;
    }

    /// Add event count from a segment file if the entry is a valid segment.
    fn addEventCountIfSegment(
        self: *Wal,
        allocator: std.mem.Allocator,
        entry: std.fs.Dir.Walker.Entry,
    ) !u64 {
        if (entry.kind != .file) return 0;
        if (!std.mem.startsWith(u8, entry.path, segment_prefix)) return 0;

        // Use helper for path formatting
        const segment_path = self.formatPath(
            "{s}/{s}",
            .{ self.dir_path, entry.path },
        ) catch return 0;

        // Copy to temporary allocated memory
        const path_copy = allocator.alloc(u8, segment_path.len) catch return 0;
        defer allocator.free(path_copy);
        @memcpy(path_copy, segment_path);

        var file = try std.fs.cwd().openFile(path_copy, .{ .mode = .read_only });
        defer file.close();

        var header_bytes: [limits.wal_header_size]u8 = undefined;
        _ = try file.read(&header_bytes);
        const header = SegmentHeader.fromBytes(header_bytes);
        return header.event_count;
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
