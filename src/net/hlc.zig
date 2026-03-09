//! Hybrid Logical Clock implementation.
//! Based on: https://css.csail.mit.edu/6.824/2014/papers/hlc.pdf

const std = @import("std");

/// HLC timestamp: physical time + logical time + node id
pub const Timestamp = packed struct {
    time: u64, // physical time (milliseconds)
    count: u16, // logical counter
    node_id: u16, // node identifier

    pub fn lessThan(a: Timestamp, b: Timestamp) bool {
        if (a.time != b.time) return a.time < b.time;
        if (a.count != b.count) return a.count < b.count;
        return a.node_id < b.node_id;
    }
};

/// Wall clock time source - implement for your platform
pub fn now() u64 {
    return std.time.milliTimestamp();
}

test "Timestamp.lessThan returns true when a.time < b.time" {
    // Arrange - two timestamps where a has earlier physical time
    const a = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };
    const b = Timestamp{ .time = 2000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when a.time > b.time" {
    // Arrange
    const a = Timestamp{ .time = 2000, .count = 5, .node_id = 1 };
    const b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert
    try std.testing.expect(false == result);
}

test "Timestamp.lessThan uses count tie-break when times are equal and a.count < b.count" {
    // Arrange - same physical time, different logical count
    const a = Timestamp{ .time = 1000, .count = 3, .node_id = 1 };
    const b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert - smaller count wins when time is equal
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when times equal and a.count > b.count" {
    // Arrange
    const a = Timestamp{ .time = 1000, .count = 7, .node_id = 1 };
    const b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert
    try std.testing.expect(false == result);
}

test "Timestamp.lessThan uses node_id tie-break when time and count are equal and a.node_id < b.node_id" {
    // Arrange - same time and count, different node_id
    const a = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };
    const b = Timestamp{ .time = 1000, .count = 5, .node_id = 3 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert - smaller node_id wins when time and count are equal
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when time and count equal and a.node_id > b.node_id" {
    // Arrange
    const a = Timestamp{ .time = 1000, .count = 5, .node_id = 5 };
    const b = Timestamp{ .time = 1000, .count = 5, .node_id = 3 };

    // Act
    const result = Timestamp.lessThan(a, b);

    // Assert
    try std.testing.expect(false == result);
}
