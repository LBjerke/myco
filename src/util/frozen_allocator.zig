// This file defines `FrozenAllocator`, a specialized memory allocator wrapper.
// Its primary function is to enforce a "no-allocation after freeze" policy:
// once the `freeze()` method is invoked, any subsequent attempt to allocate
// or grow memory using this allocator will result in a panic. This mechanism
// is crucial for verifying that specific runtime paths in the Myco system
// operate without dynamic memory allocations after an initial setup phase,
// thereby ensuring predictable performance and preventing memory leaks in
// critical sections of the application.
//
const std = @import("std");

/// Wraps an allocator and panics on any allocation after freeze().
pub const FrozenAllocator = struct {
    inner: std.mem.Allocator,
    frozen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(inner: std.mem.Allocator) FrozenAllocator {
        return .{ .inner = inner };
    }

    pub fn allocator(self: *FrozenAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn freeze(self: *FrozenAllocator) void {
        self.frozen.store(true, .seq_cst);
    }

    pub fn isFrozen(self: *const FrozenAllocator) bool {
        return self.frozen.load(.seq_cst);
    }

    pub fn assertFrozen(self: *const FrozenAllocator) void {
        if (!self.isFrozen()) {
            @panic("no-alloc guard: allocator not frozen");
        }
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FrozenAllocator = @ptrCast(@alignCast(ptr));
        if (self.frozen.load(.seq_cst)) {
            @panic("allocation after freeze");
        }
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FrozenAllocator = @ptrCast(@alignCast(ptr));
        if (self.frozen.load(.seq_cst) and new_len > buf.len) {
            @panic("resize (grow) after freeze");
        }
        return self.inner.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FrozenAllocator = @ptrCast(@alignCast(ptr));
        if (self.frozen.load(.seq_cst) and new_len > buf.len) {
            @panic("remap (grow) after freeze");
        }
        return self.inner.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FrozenAllocator = @ptrCast(@alignCast(ptr));
        self.inner.rawFree(buf, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
