//! Event types for WAL persistence.
//! All events are serializable for disk storage.

const std = @import("std");
const hlc = @import("../net/hlc.zig");
const Timestamp = hlc.Timestamp;
const assert = @import("../util/assert.zig");

/// Read a little-endian u16 from reader.
fn readU16(reader: anytype) !u16 {
    return reader.readInt(u16, .little);
}

/// Read N bytes from reader into a fixed-size array.
fn readBytes(reader: anytype, comptime n: usize) ![n]u8 {
    var bytes: [n]u8 = undefined;
    try reader.readNoEof(&bytes);
    return bytes;
}

/// Serialize a Timestamp to writer.
fn serializeTimestamp(writer: anytype, ts: Timestamp) !void {
    try writer.writeInt(u64, ts.time, .little);
    try writer.writeInt(u16, ts.count, .little);
    try writer.writeInt(u16, ts.node_id, .little);
}

/// Deserialize a Timestamp from reader.
fn deserializeTimestamp(reader: anytype) !Timestamp {
    const time = try reader.readInt(u64, .little);
    const count = try reader.readInt(u16, .little);
    const node_id = try reader.readInt(u16, .little);
    return .{ .time = time, .count = count, .node_id = node_id };
}

/// Event type identifiers for serialization.
pub const EventType = enum(u8) {
    node_join = 1,
    node_leave = 2,
    service_deploy = 3,
    service_remove = 4,
    health_status_change = 5,
};

/// Node joined the cluster.
pub const NodeJoinEvent = struct {
    node_id: u16,
    address: [4]u8, // IPv4 address bytes
    port: u16,
    timestamp: Timestamp,

    pub fn serialize(self: NodeJoinEvent, writer: anytype) !void {
        try writer.writeInt(u16, self.node_id, .little);
        try writer.writeAll(&self.address);
        try writer.writeInt(u16, self.port, .little);
        try serializeTimestamp(writer, self.timestamp);
    }

    pub fn deserialize(reader: anytype) !NodeJoinEvent {
        const node_id = try readU16(reader);
        const address = try readBytes(reader, 4);
        const port = try readU16(reader);
        const timestamp = try deserializeTimestamp(reader);

        return NodeJoinEvent{
            .node_id = node_id,
            .address = address,
            .port = port,
            .timestamp = timestamp,
        };
    }
};

/// Node left the cluster.
pub const NodeLeaveEvent = struct {
    node_id: u16,
    timestamp: Timestamp,

    pub fn serialize(self: NodeLeaveEvent, writer: anytype) !void {
        try writer.writeInt(u16, self.node_id, .little);
        try serializeTimestamp(writer, self.timestamp);
    }

    pub fn deserialize(reader: anytype) !NodeLeaveEvent {
        const node_id = try readU16(reader);
        const timestamp = try deserializeTimestamp(reader);

        return NodeLeaveEvent{
            .node_id = node_id,
            .timestamp = timestamp,
        };
    }
};

/// Service deployed to the cluster.
pub const ServiceDeployEvent = struct {
    service_id: u16,
    name: [32]u8, // Fixed-size name buffer
    name_len: u8,
    replicas: u8,
    timestamp: Timestamp,

    pub fn serialize(self: ServiceDeployEvent, writer: anytype) !void {
        try writer.writeInt(u16, self.service_id, .little);
        try writer.writeAll(&self.name);
        try writer.writeByte(self.name_len);
        try writer.writeByte(self.replicas);
        try serializeTimestamp(writer, self.timestamp);
    }

    pub fn deserialize(reader: anytype) !ServiceDeployEvent {
        const service_id = try readU16(reader);
        const name = try readBytes(reader, 32);
        const name_len = try reader.readByte();

        // NASA Power of 10 Rule 5: Assert name_len is within buffer bounds
        assert.assertBounds(name_len, name.len + 1, "ServiceDeployEvent name_len exceeds buffer");

        const replicas = try reader.readByte();

        // NASA Power of 10 Rule 5: Assert replicas is reasonable (not zero, not insane)
        assert.assert(replicas > 0 and replicas < 128, "ServiceDeployEvent replicas out of valid range");

        const timestamp = try deserializeTimestamp(reader);

        return ServiceDeployEvent{
            .service_id = service_id,
            .name = name,
            .name_len = name_len,
            .replicas = replicas,
            .timestamp = timestamp,
        };
    }

    /// Get the service name as a slice.
    pub fn getName(self: ServiceDeployEvent) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Service removed from the cluster.
pub const ServiceRemoveEvent = struct {
    service_id: u16,
    timestamp: Timestamp,

    pub fn serialize(self: ServiceRemoveEvent, writer: anytype) !void {
        try writer.writeInt(u16, self.service_id, .little);
        try serializeTimestamp(writer, self.timestamp);
    }

    pub fn deserialize(reader: anytype) !ServiceRemoveEvent {
        const service_id = try readU16(reader);
        const timestamp = try deserializeTimestamp(reader);

        return ServiceRemoveEvent{
            .service_id = service_id,
            .timestamp = timestamp,
        };
    }
};

/// Health status changed for a node.
pub const HealthStatusChangeEvent = struct {
    node_id: u16,
    new_status: u8, // NodeHealthStatus enum value
    timestamp: Timestamp,

    pub fn serialize(self: HealthStatusChangeEvent, writer: anytype) !void {
        try writer.writeInt(u16, self.node_id, .little);
        try writer.writeByte(self.new_status);
        try serializeTimestamp(writer, self.timestamp);
    }

    pub fn deserialize(reader: anytype) !HealthStatusChangeEvent {
        const node_id = try readU16(reader);
        const new_status = try reader.readByte();

        // NASA Power of 10 Rule 5: Assert health status is valid enum value
        assert.assertLessThan(u8, new_status, 4, "HealthStatusChangeEvent status out of valid range");

        const timestamp = try deserializeTimestamp(reader);

        return HealthStatusChangeEvent{
            .node_id = node_id,
            .new_status = new_status,
            .timestamp = timestamp,
        };
    }
};

/// Discriminated union of all event types.
pub const Event = union(EventType) {
    node_join: NodeJoinEvent,
    node_leave: NodeLeaveEvent,
    service_deploy: ServiceDeployEvent,
    service_remove: ServiceRemoveEvent,
    health_status_change: HealthStatusChangeEvent,

    /// Serialize event to writer.
    pub fn serialize(event: Event, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(@as(EventType, event)));
        switch (event) {
            .node_join => |e| try e.serialize(writer),
            .node_leave => |e| try e.serialize(writer),
            .service_deploy => |e| try e.serialize(writer),
            .service_remove => |e| try e.serialize(writer),
            .health_status_change => |e| try e.serialize(writer),
        }
    }

    /// Deserialize event from reader.
    pub fn deserialize(reader: anytype) !Event {
        const event_type_val = try reader.readByte();

        // Validate enum value before conversion
        // NASA Power of 10 Rule 5: Add assertions for anomalous conditions
        if (event_type_val < 1 or event_type_val > 5) {
            return error.InvalidEventType;
        }

        // Assert: event type should be valid (1-5 range checked above)
        assert.assert(event_type_val >= 1 and event_type_val <= 5, "Invalid event type in deserialize");

        const event_type: EventType = @enumFromInt(event_type_val);
        switch (event_type) {
            .node_join => return .{ .node_join = try NodeJoinEvent.deserialize(reader) },
            .node_leave => return .{ .node_leave = try NodeLeaveEvent.deserialize(reader) },
            .service_deploy => return .{ .service_deploy = try ServiceDeployEvent.deserialize(reader) },
            .service_remove => return .{ .service_remove = try ServiceRemoveEvent.deserialize(reader) },
            .health_status_change => return .{ .health_status_change = try HealthStatusChangeEvent.deserialize(reader) },
        }
    }

    /// Get timestamp from event.
    pub fn getTimestamp(self: Event) Timestamp {
        return switch (self) {
            .node_join => |e| e.timestamp,
            .node_leave => |e| e.timestamp,
            .service_deploy => |e| e.timestamp,
            .service_remove => |e| e.timestamp,
            .health_status_change => |e| e.timestamp,
        };
    }
};

/// Event with metadata for WAL storage.
pub const WalEvent = struct {
    event: Event,
    checksum: u32 = 0,

    /// Serialize WalEvent to writer.
    pub fn serialize(self: WalEvent, writer: anytype) !void {
        try writer.writeInt(u32, self.checksum, .little);
        try self.event.serialize(writer);
    }

    /// Deserialize WalEvent from reader.
    pub fn deserialize(reader: anytype) !WalEvent {
        const checksum = try reader.readInt(u32, .little);

        // NASA Power of 10 Rule 5: Assert checksum is non-zero (should always be set)
        assert.assert(checksum != 0, "WalEvent checksum should never be zero");

        const event = try Event.deserialize(reader);

        // Verify checksum
        const calculated_checksum = calculateChecksum(event);

        // NASA Power of 10 Rule 5: Assert checksum integrity
        assert.assert(calculated_checksum == checksum, "WalEvent checksum mismatch - data corrupted");

        if (calculated_checksum != checksum) {
            return error.ChecksumMismatch;
        }

        return WalEvent{
            .event = event,
            .checksum = checksum,
        };
    }

    /// Calculate a simple checksum for the event.
    ///
    /// NOTE: This is a simple XOR-based hash, NOT a real CRC32.
    /// It is intentionally weak and suitable only for basic sanity checks.
    /// For production use, replace with proper CRC32 or cryptographic hash.
    /// The checksum IS verified during WalEvent.deserialize (WAL reads).
    pub fn calculateChecksum(event: Event) u32 {
        // Simple hash-based checksum - NOT for data integrity verification
        var hash: u32 = 0;
        const timestamp = event.getTimestamp();
        hash ^= @truncate(timestamp.time);
        hash ^= (@as(u32, timestamp.count) << 16);
        hash ^= (@as(u32, timestamp.node_id) << 8);
        return hash;
    }

    /// Create a new WalEvent with checksum.
    pub fn create(event: Event) WalEvent {
        return WalEvent{
            .event = event,
            .checksum = calculateChecksum(event),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NodeJoinEvent serialize/deserialize roundtrip" {
    const event = NodeJoinEvent{
        .node_id = 42,
        .address = .{ 192, 168, 1, 100 },
        .port = 8080,
        .timestamp = .{ .time = 1000, .count = 5, .node_id = 1 },
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try event.serialize(fbs.writer());

    fbs.reset();
    const deserialized = try NodeJoinEvent.deserialize(fbs.reader());

    try std.testing.expectEqual(event.node_id, deserialized.node_id);
    try std.testing.expectEqualSlices(u8, &event.address, &deserialized.address);
    try std.testing.expectEqual(event.port, deserialized.port);
}

test "ServiceDeployEvent getName returns correct slice" {
    var name_buffer: [32]u8 = undefined;
    @memcpy(name_buffer[0..10], "my-service");

    const event = ServiceDeployEvent{
        .service_id = 1,
        .name = name_buffer,
        .name_len = 10,
        .replicas = 3,
        .timestamp = .{ .time = 1000, .count = 0, .node_id = 0 },
    };

    try std.testing.expectEqualStrings("my-service", event.getName());
}

test "Event deserialize reads correct type" {
    const original = NodeJoinEvent{
        .node_id = 99,
        .address = .{ 10, 0, 0, 1 },
        .port = 9000,
        .timestamp = .{ .time = 2000, .count = 10, .node_id = 2 },
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try (Event{ .node_join = original }).serialize(fbs.writer());

    fbs.reset();
    const event = try Event.deserialize(fbs.reader());

    try std.testing.expectEqual(EventType.node_join, @as(EventType, event));
    try std.testing.expectEqual(original.node_id, event.node_join.node_id);
}

test "WalEvent create calculates checksum" {
    const event = NodeJoinEvent{
        .node_id = 1,
        .address = .{ 0, 0, 0, 0 },
        .port = 0,
        .timestamp = .{ .time = 100, .count = 5, .node_id = 3 },
    };

    const wal_event = WalEvent.create(.{ .node_join = event });
    try std.testing.expect(wal_event.checksum != 0);
}

test "NodeLeaveEvent serialize/deserialize roundtrip" {
    const event = NodeLeaveEvent{
        .node_id = 42,
        .timestamp = .{ .time = 2000, .count = 3, .node_id = 1 },
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try event.serialize(fbs.writer());

    fbs.reset();
    const deserialized = try NodeLeaveEvent.deserialize(fbs.reader());

    try std.testing.expectEqual(event.node_id, deserialized.node_id);
}

test "ServiceRemoveEvent serialize/deserialize roundtrip" {
    const event = ServiceRemoveEvent{
        .service_id = 7,
        .timestamp = .{ .time = 3000, .count = 4, .node_id = 2 },
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try event.serialize(fbs.writer());

    fbs.reset();
    const deserialized = try ServiceRemoveEvent.deserialize(fbs.reader());

    try std.testing.expectEqual(event.service_id, deserialized.service_id);
}

test "HealthStatusChangeEvent serialize/deserialize roundtrip" {
    const event = HealthStatusChangeEvent{
        .node_id = 5,
        .new_status = 1, // degraded
        .timestamp = .{ .time = 4000, .count = 6, .node_id = 3 },
    };

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try event.serialize(fbs.writer());

    fbs.reset();
    const deserialized = try HealthStatusChangeEvent.deserialize(fbs.reader());

    try std.testing.expectEqual(event.node_id, deserialized.node_id);
    try std.testing.expectEqual(event.new_status, deserialized.new_status);
}

test "WalEvent serialize/deserialize roundtrip with checksum" {
    const event = NodeJoinEvent{
        .node_id = 99,
        .address = .{ 10, 0, 0, 1 },
        .port = 9000,
        .timestamp = .{ .time = 5000, .count = 10, .node_id = 4 },
    };

    const wal_event = WalEvent.create(.{ .node_join = event });

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try wal_event.serialize(fbs.writer());

    fbs.reset();
    const deserialized = try WalEvent.deserialize(fbs.reader());

    try std.testing.expectEqual(wal_event.checksum, deserialized.checksum);
    try std.testing.expectEqual(event.node_id, deserialized.event.node_join.node_id);
}

test "Event deserialize invalid type returns error" {
    // Write an invalid event type (0 is not valid)
    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try fbs.writer().writeByte(0); // Invalid type

    fbs.reset();
    const result = Event.deserialize(fbs.reader());
    try std.testing.expectError(error.InvalidEventType, result);
}

test "Event getTimestamp returns correct timestamp for all event types" {
    const ts = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    const event1 = Event{ .node_join = NodeJoinEvent{ .node_id = 1, .address = .{ 0, 0, 0, 0 }, .port = 8080, .timestamp = ts } };
    try std.testing.expectEqual(ts.time, event1.getTimestamp().time);

    const event2 = Event{ .node_leave = NodeLeaveEvent{ .node_id = 1, .timestamp = ts } };
    try std.testing.expectEqual(ts.time, event2.getTimestamp().time);

    const name_buf: [32]u8 = undefined;
    const event3 = Event{ .service_deploy = ServiceDeployEvent{ .service_id = 1, .name = name_buf, .name_len = 4, .replicas = 1, .timestamp = ts } };
    try std.testing.expectEqual(ts.time, event3.getTimestamp().time);

    const event4 = Event{ .service_remove = ServiceRemoveEvent{ .service_id = 1, .timestamp = ts } };
    try std.testing.expectEqual(ts.time, event4.getTimestamp().time);

    const event5 = Event{ .health_status_change = HealthStatusChangeEvent{ .node_id = 1, .new_status = 0, .timestamp = ts } };
    try std.testing.expectEqual(ts.time, event5.getTimestamp().time);
}
