//! Event types for WAL persistence.
//! All events are serializable for disk storage.

const std = @import("std");
const hlc = @import("../net/hlc.zig");
const Timestamp = hlc.Timestamp;

/// Read a little-endian u16 from reader.
fn readU16(reader: anytype) !u16 {
    var bytes: [2]u8 = undefined;
    try reader.readNoEof(&bytes);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

/// Read a little-endian u64 from reader.
fn readU64(reader: anytype) !u64 {
    var bytes: [8]u8 = undefined;
    try reader.readNoEof(&bytes);
    var result: u64 = 0;
    for (0..bytes.len) |i| {
        result |= @as(u64, bytes[i]) << @as(u6, @intCast(i * 8));
    }
    return result;
}

/// Read N bytes from reader into a fixed-size array.
fn readBytes(reader: anytype, comptime n: usize) ![n]u8 {
    var bytes: [n]u8 = undefined;
    try reader.readNoEof(&bytes);
    return bytes;
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
        try writer.writeByte(@intFromEnum(EventType.node_join));
        try writer.writeInt(u16, self.node_id, .little);
        try writer.writeAll(&self.address);
        try writer.writeInt(u16, self.port, .little);
        try writer.writeInt(u64, self.timestamp.time, .little);
        try writer.writeInt(u16, self.timestamp.count, .little);
        try writer.writeInt(u16, self.timestamp.node_id, .little);
    }

    pub fn deserialize(reader: anytype) !NodeJoinEvent {
        const node_id = try readU16(reader);
        const address = try readBytes(reader, 4);
        const port = try readU16(reader);
        const timestamp_time = try readU64(reader);
        const timestamp_count = try readU16(reader);
        const timestamp_node_id = try readU16(reader);

        return NodeJoinEvent{
            .node_id = node_id,
            .address = address,
            .port = port,
            .timestamp = .{
                .time = timestamp_time,
                .count = timestamp_count,
                .node_id = timestamp_node_id,
            },
        };
    }
};

/// Node left the cluster.
pub const NodeLeaveEvent = struct {
    node_id: u16,
    timestamp: Timestamp,

    pub fn serialize(self: NodeLeaveEvent, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(EventType.node_leave));
        try writer.writeInt(u16, self.node_id, .little);
        try writer.writeInt(u64, self.timestamp.time, .little);
        try writer.writeInt(u16, self.timestamp.count, .little);
        try writer.writeInt(u16, self.timestamp.node_id, .little);
    }

    pub fn deserialize(reader: anytype) !NodeLeaveEvent {
        const node_id = try readU16(reader);
        const timestamp_time = try readU64(reader);
        const timestamp_count = try readU16(reader);
        const timestamp_node_id = try readU16(reader);

        return NodeLeaveEvent{
            .node_id = node_id,
            .timestamp = .{
                .time = timestamp_time,
                .count = timestamp_count,
                .node_id = timestamp_node_id,
            },
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
        try writer.writeByte(@intFromEnum(EventType.service_deploy));
        try writer.writeInt(u16, self.service_id, .little);
        try writer.writeAll(&self.name);
        try writer.writeByte(self.name_len);
        try writer.writeByte(self.replicas);
        try writer.writeInt(u64, self.timestamp.time, .little);
        try writer.writeInt(u16, self.timestamp.count, .little);
        try writer.writeInt(u16, self.timestamp.node_id, .little);
    }

    pub fn deserialize(reader: anytype) !ServiceDeployEvent {
        const service_id = try readU16(reader);
        const name = try readBytes(reader, 32);
        const name_len = try reader.readByte();
        const replicas = try reader.readByte();
        const timestamp_time = try readU64(reader);
        const timestamp_count = try readU16(reader);
        const timestamp_node_id = try readU16(reader);

        return ServiceDeployEvent{
            .service_id = service_id,
            .name = name,
            .name_len = name_len,
            .replicas = replicas,
            .timestamp = .{
                .time = timestamp_time,
                .count = timestamp_count,
                .node_id = timestamp_node_id,
            },
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
        try writer.writeByte(@intFromEnum(EventType.service_remove));
        try writer.writeInt(u16, self.service_id, .little);
        try writer.writeInt(u64, self.timestamp.time, .little);
        try writer.writeInt(u16, self.timestamp.count, .little);
        try writer.writeInt(u16, self.timestamp.node_id, .little);
    }

    pub fn deserialize(reader: anytype) !ServiceRemoveEvent {
        const service_id = try readU16(reader);
        const timestamp_time = try readU64(reader);
        const timestamp_count = try readU16(reader);
        const timestamp_node_id = try readU16(reader);

        return ServiceRemoveEvent{
            .service_id = service_id,
            .timestamp = .{
                .time = timestamp_time,
                .count = timestamp_count,
                .node_id = timestamp_node_id,
            },
        };
    }
};

/// Health status changed for a node.
pub const HealthStatusChangeEvent = struct {
    node_id: u16,
    new_status: u8, // NodeHealthStatus enum value
    timestamp: Timestamp,

    pub fn serialize(self: HealthStatusChangeEvent, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(EventType.health_status_change));
        try writer.writeInt(u16, self.node_id, .little);
        try writer.writeByte(self.new_status);
        try writer.writeInt(u64, self.timestamp.time, .little);
        try writer.writeInt(u16, self.timestamp.count, .little);
        try writer.writeInt(u16, self.timestamp.node_id, .little);
    }

    pub fn deserialize(reader: anytype) !HealthStatusChangeEvent {
        const node_id = try readU16(reader);
        const new_status = try reader.readByte();
        const timestamp_time = try readU64(reader);
        const timestamp_count = try readU16(reader);
        const timestamp_node_id = try readU16(reader);

        return HealthStatusChangeEvent{
            .node_id = node_id,
            .new_status = new_status,
            .timestamp = .{
                .time = timestamp_time,
                .count = timestamp_count,
                .node_id = timestamp_node_id,
            },
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
        if (event_type_val < 1 or event_type_val > 5) {
            return error.InvalidEventType;
        }

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
        const event = try Event.deserialize(reader);

        // Verify checksum
        const calculated_checksum = calculateChecksum(event);
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
    /// Also note: the checksum is currently written but never verified during WAL reads.
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
    try original.serialize(fbs.writer());

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
