// This file implements a runtime check mechanism (`noalloc_guard`) to ensure
// that no dynamic memory allocations occur in critical sections of the code
// after a `FrozenAllocator` has been activated. It provides functions to
// activate and deactivate a global guard, and the `check()` function asserts
// that the associated `FrozenAllocator` is indeed frozen. This mechanism
// works in conjunction with `FrozenAllocator` to enforce and verify
// zero-allocation guarantees for enhanced performance and stability within
// the Myco system.
//
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
