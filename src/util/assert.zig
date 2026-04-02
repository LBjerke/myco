//! Runtime assertion helpers for safety-critical code.
//! Follows NASA Power of 10 Rule 5: assertion density.
//!
//! These assertions are designed for runtime safety checking - they panic
//! if an anomalous condition is detected that should never happen in real
//! execution. This is different from test assertions which are only used
//! during testing.
//!
//! Guidelines:
//! - Assertions check for conditions that SHOULD NEVER happen
//! - Assertions are side-effect free
//! - When an assertion fails, it's a bug in the code, not expected runtime state

const std = @import("std");

/// Assert a condition is true - panics with message if false.
/// Use for: checking invariants, validating internal state, detecting bugs.
pub inline fn assert(cond: bool, msg: []const u8) void {
    if (!cond) @panic(msg);
}

/// Assert two values are equal - panics if not equal.
/// Use for: validating internal consistency.
pub inline fn assertEqual(comptime T: type, expected: T, actual: T, msg: []const u8) void {
    if (expected != actual) {
        std.debug.print(
            "Assertion failed: expected {any}, got {any} - {s}\n",
            .{ expected, actual, msg },
        );
        @panic(msg);
    }
}

/// Assert a value is within bounds [0, max).
/// Use for: validating array indices, buffer positions.
pub inline fn assertBounds(val: usize, max: usize, msg: []const u8) void {
    if (val >= max) {
        std.debug.print("Assertion failed: value {} >= max {} - {s}\n", .{ val, max, msg });
        @panic(msg);
    }
}

/// Assert a value is less than a maximum.
/// Use for: validating counts, sizes.
pub inline fn assertLessThan(comptime T: type, val: T, max: T, msg: []const u8) void {
    if (val >= max) {
        std.debug.print("Assertion failed: {} >= {} - {s}\n", .{ val, max, msg });
        @panic(msg);
    }
}

/// Assert two slices have equal length.
/// Use for: validating buffer sizes match.
pub inline fn assertSliceLen(a: []const u8, b: []const u8, msg: []const u8) void {
    if (a.len != b.len) {
        std.debug.print("Assertion failed: slice len {} != {} - {s}\n", .{ a.len, b.len, msg });
        @panic(msg);
    }
}

/// Assert a pointer/value is not null/zero.
/// Use for: validating pointers, optionals.
pub inline fn assertNotNull(comptime T: type, val: T, msg: []const u8) void {
    if (val == 0) {
        @panic(msg);
    }
}

/// Assert a condition is false - panics if true.
/// Use for: checking that something that shouldn't happen doesn't.
pub inline fn assertFalse(cond: bool, msg: []const u8) void {
    if (cond) @panic(msg);
}

/// Unreachable assertion - use when code should never reach this point.
/// Panics with the given message if reached.
/// Note: This shadows the built-in @unreachable - use assertUnreachable to call.
pub inline fn assertUnreachable(msg: []const u8) void {
    @panic("UNREACHABLE: " ++ msg);
}

// ============================================================================
// Test the assert module itself
// ============================================================================

test "assert module: basic assertions work" {
    // Test assert
    assert(true, "this should not panic");

    // Test assertEqual
    assertEqual(u32, 42, 42, "equal values");
    assertEqual(i16, -5, -5, "negative equal");

    // Test assertBounds
    assertBounds(5, 10, "in bounds");
    assertBounds(0, 10, "zero is valid");

    // Test assertLessThan
    assertLessThan(u32, 5, 10, "5 < 10");
    assertLessThan(i32, -1, 0, "negative < positive");

    // Test assertSliceLen
    assertSliceLen(&[_]u8{ 1, 2, 3 }, &[_]u8{ 4, 5, 6 }, "equal len");
}
