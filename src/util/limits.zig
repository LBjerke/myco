//! Constants and bounds for the Myco system.

const std = @import("std");

pub const PACKET_SIZE: usize = 1024;

pub const MAX_NODES: usize = 64;
pub const MAX_SERVICES: usize = 256;
pub const MAX_REPLICAS_PER_SERVICE: usize = 8;
pub const MAX_PLACEMENTS: usize = MAX_SERVICES * MAX_REPLICAS_PER_SERVICE;

pub const MAX_NODE_ID: u16 = MAX_NODES;
pub const MAX_SERVICE_ID: u16 = MAX_SERVICES;

pub const GOSSIP_INTERVAL_MS: u32 = 1000;
pub const TICK_INTERVAL_MS: u32 = 100;

// WAL constants
pub const WAL_HEADER_SIZE: usize = 25;
pub const WAL_TEMP_BUFFER_SIZE: usize = 65536;
pub const WAL_WRITE_BUFFER_SIZE: usize = 64 * 1024;
pub const WAL_MAX_SEGMENTS: usize = 1000;
pub const WAL_SEGMENT_PREFIX = "segment-";
pub const WAL_TEMP_PREFIX = ".tmp-";

test "PACKET_SIZE equals 1024" {
    // Arrange & Act - access the constant
    const size = PACKET_SIZE;

    // Assert - verify expected value
    try std.testing.expectEqual(@as(usize, 1024), size);
}

test "MAX_NODES equals 64" {
    // Arrange & Act
    const max = MAX_NODES;

    // Assert
    try std.testing.expectEqual(@as(usize, 64), max);
}

test "MAX_SERVICES equals 256" {
    // Arrange & Act
    const max = MAX_SERVICES;

    // Assert
    try std.testing.expectEqual(@as(usize, 256), max);
}

test "MAX_REPLICAS_PER_SERVICE equals 8" {
    // Arrange & Act
    const max = MAX_REPLICAS_PER_SERVICE;

    // Assert
    try std.testing.expectEqual(@as(usize, 8), max);
}

test "MAX_PLACEMENTS equals MAX_SERVICES times MAX_REPLICAS_PER_SERVICE" {
    // Arrange - expected calculation
    const expected = MAX_SERVICES * MAX_REPLICAS_PER_SERVICE;

    // Act - get the constant
    const actual = MAX_PLACEMENTS;

    // Assert - verify calculation is correct
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectEqual(@as(usize, 2048), actual); // 256 * 8 = 2048
}
