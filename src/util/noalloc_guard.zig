const std = @import("std");
const FrozenAllocator = @import("frozen_allocator.zig").FrozenAllocator;

var guard_ptr = std.atomic.Value(usize).init(0);

pub fn activate(frozen: *const FrozenAllocator) void {
    guard_ptr.store(@intFromPtr(frozen), .seq_cst);
}

pub fn deactivate() void {
    guard_ptr.store(0, .seq_cst);
}

pub fn check() void {
    const ptr = guard_ptr.load(.seq_cst);
    if (ptr != 0) {
        const frozen: *const FrozenAllocator = @ptrFromInt(ptr);
        frozen.assertFrozen();
    }
}
