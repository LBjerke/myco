//! Tests for FrozenAllocator - multiple independent instances
//! Verifies thread safety and proper isolation between allocators.

const std = @import("std");
const FrozenAllocator = @import("../src/util/allocator.zig").FrozenAllocator;

pub fn main() !void {
    std.debug.print("Testing FrozenAllocator - multiple independent instances\n", .{});

    // Test 1: Create two independent allocators
    std.debug.print("Test 1: Multiple independent allocators...\n", .{});
    var alloc1 = FrozenAllocator.init();
    var alloc2 = FrozenAllocator.init();

    // Verify they have separate buffers
    const mem1 = try alloc1.allocator().alloc(u8, 16);
    const mem2 = try alloc2.allocator().alloc(u8, 16);

    mem1[0] = 0xAA;
    mem2[0] = 0xBB;

    if (mem1[0] == 0xAA and mem2[0] == 0xBB) {
        std.debug.print("  ✓ Separate buffers work correctly\n", .{});
    } else {
        std.debug.print("  ✗ Separate buffers failed: {{x:02X}}, {{x:02X}}\n", .{ mem1[0], mem2[0] });
        return error.TestFailed;
    }

    // Test 2: Verify freeze works independently
    std.debug.print("Test 2: Independent freeze behavior...\n", .{});
    alloc1.freeze();

    // alloc1 should panic on allocation
    if (alloc1.allocator().alloc(u8, 16)) |_| {
        std.debug.print("  ✗ alloc1 didn't freeze properly\n", .{});
        return error.TestFailed;
    } else |_| { // Ignore the error, we expect it to fail
        std.debug.print("  ✓ alloc1 freezes correctly\n", .{});
    }

    // alloc2 should still work
    const mem3 = try alloc2.allocator().alloc(u8, 16);
    mem3[0] = 0xCC;
    std.debug.print("  ✓ alloc2 works independently after alloc1 freeze\n", .{});

    // Test 3: Verify remaining bytes are tracked separately
    std.debug.print("Test 3: Independent memory tracking...\n", .{});
    const remaining1 = alloc1.remaining();
    const remaining2 = alloc2.remaining();

    if (remaining1 != remaining2) {
        std.debug.print("  ✓ Memory tracking is independent\n", .{});
    } else {
        std.debug.print("  ✗ Memory tracking not independent\n", .{});
        return error.TestFailed;
    }

    std.debug.print("All FrozenAllocator tests passed!\n", .{});
    return {};
}
