//! Constants and bounds for the Myco system.

const std = @import("std");

pub const packet_size: usize = 1024;

pub const max_nodes: usize = 64;
pub const max_services: usize = 256;
pub const max_replicas_per_service: usize = 8;
pub const max_placements: usize = max_services * max_replicas_per_service;

pub const max_node_id: u16 = max_nodes;
pub const max_service_id: u16 = max_services;

pub const gossip_interval_ms: u32 = 1000;
pub const tick_interval_ms: u32 = 100;

// WAL constants
pub const wal_header_size: usize = 25;
pub const wal_temp_buffer_size: usize = 65536;
pub const wal_write_buffer_size: usize = 64 * 1024;
pub const wal_max_segments: usize = 1000;
pub const wal_segment_prefix = "segment-";
pub const wal_temp_prefix = ".tmp-";

test "packet_size equals 1024" {
    // Arrange & Act - access the constant
    const size = packet_size;

    // Assert - verify expected value
    try std.testing.expectEqual(@as(usize, 1024), size);
}

test "max_nodes equals 64" {
    // Arrange & Act
    const max = max_nodes;

    // Assert
    try std.testing.expectEqual(@as(usize, 64), max);
}

test "max_services equals 256" {
    // Arrange & Act
    const max = max_services;

    // Assert
    try std.testing.expectEqual(@as(usize, 256), max);
}

test "max_replicas_per_service equals 8" {
    // Arrange & Act
    const max = max_replicas_per_service;

    // Assert
    try std.testing.expectEqual(@as(usize, 8), max);
}

test "max_placements equals max_services times max_replicas_per_service" {
    // Arrange - expected calculation
    const expected = max_services * max_replicas_per_service;

    // Act - get the constant
    const actual = max_placements;

    // Assert - verify calculation is correct
    try std.testing.expectEqual(expected, actual);
    try std.testing.expectEqual(@as(usize, 2048), actual); // 256 * 8 = 2048
}
