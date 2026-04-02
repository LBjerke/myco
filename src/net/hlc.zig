//! Hybrid Logical Clock implementation.
//! Based on: https://css.csail.mit.edu/6.824/2014/papers/hlc.pdf

const std = @import("std");
const assert = @import("../util/assert.zig");

/// HLC timestamp: physical time + logical time + node id
pub const Timestamp = packed struct {
    time: u64, // physical time (milliseconds)
    count: u16, // logical counter
    node_id: u16, // node identifier

    pub fn lessThan(a: Timestamp, b: Timestamp) bool {
        // NASA Power of 10 Rule 5: Assert valid timestamps
        // Timestamps with time=0 are uninitialized and should not be compared
        assert.assert(a.time != 0, "lessThan: a.timestamp is uninitialized (time=0)");
        assert.assert(b.time != 0, "lessThan: b.timestamp is uninitialized (time=0)");

        if (a.time != b.time) return a.time < b.time;
        if (a.count != b.count) return a.count < b.count;
        return a.node_id < b.node_id;
    }
};

/// Time source function type - can be replaced for testing
var timeSourceFn: *const fn () u64 = std.time.milliTimestamp;

/// Get current wall clock time in milliseconds.
pub fn now() u64 {
    return timeSourceFn();
}

/// Set a custom time source (for testing).
pub fn setTimeSource(source: *const fn () u64) void {
    timeSourceFn = source;
}

/// Reset to default time source.
pub fn resetTimeSource() void {
    timeSourceFn = std.time.milliTimestamp;
}

test "Timestamp.lessThan returns true when a.time < b.time" {
    // Arrange - two timestamps where a has earlier physical time
    const ts_a = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };
    const ts_b = Timestamp{ .time = 2000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when a.time > b.time" {
    // Arrange
    const ts_a = Timestamp{ .time = 2000, .count = 5, .node_id = 1 };
    const ts_b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert
    try std.testing.expect(false == result);
}

test "Timestamp.lessThan uses count tie-break when times are equal and a.count < b.count" {
    // Arrange - same physical time, different logical count
    const ts_a = Timestamp{ .time = 1000, .count = 3, .node_id = 1 };
    const ts_b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert - smaller count wins when time is equal
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when times equal and a.count > b.count" {
    // Arrange
    const ts_a = Timestamp{ .time = 1000, .count = 7, .node_id = 1 };
    const ts_b = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert
    try std.testing.expect(false == result);
}

test "Timestamp.lessThan uses node_id tie-break when equal" {
    // Arrange - same time and count, different node_id
    const ts_a = Timestamp{ .time = 1000, .count = 5, .node_id = 1 };
    const ts_b = Timestamp{ .time = 1000, .count = 5, .node_id = 3 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert - smaller node_id wins when time and count are equal
    try std.testing.expect(true == result);
}

test "Timestamp.lessThan returns false when time and count equal and a.node_id > b.node_id" {
    // Arrange
    const ts_a = Timestamp{ .time = 1000, .count = 5, .node_id = 5 };
    const ts_b = Timestamp{ .time = 1000, .count = 5, .node_id = 3 };

    // Act
    const result = Timestamp.lessThan(ts_a, ts_b);

    // Assert
    try std.testing.expect(false == result);
}
