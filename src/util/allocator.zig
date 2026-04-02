//! Zero-allocation runtime support.
//! Provides frozen allocator for init-time allocations.

const std = @import("std");
const assert = @import("../util/assert.zig");

/// A frozen allocator that prevents allocations after initialization.
/// Once frozen, any allocation attempt will panic.
///
/// Use this during init to allocate dynamic structures, then freeze
/// to ensure no allocations occur during the runtime loop.
pub const FrozenAllocator = struct {
    buffer: []u8,
    offset: usize = 0,
    frozen: bool = false,

    /// Initialize with a static buffer
    pub fn init(buffer: []u8) FrozenAllocator {
        return FrozenAllocator{
            .buffer = buffer,
            .offset = 0,
            .frozen = false,
        };
    }

    /// Get the allocator interface
    pub fn allocator(self: *FrozenAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// Freeze the allocator - any future allocations will panic
    pub fn freeze(self: *FrozenAllocator) void {
        self.frozen = true;
    }

    /// Check if frozen
    pub fn isFrozen(self: *const FrozenAllocator) bool {
        return self.frozen;
    }

    /// Get remaining bytes available
    pub fn remaining(self: *const FrozenAllocator) usize {
        return self.buffer.len - self.offset;
    }

    /// Reset (for testing - not for production use after freeze)
    pub fn reset(self: *FrozenAllocator) void {
        self.offset = 0;
        self.frozen = false;
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        ptr_align: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *FrozenAllocator = @ptrCast(@alignCast(ctx));
        _ = ret_addr;

        // NASA Power of 10 Rule 5: Assert allocator is not frozen
        assert.assert(!self.frozen, "FrozenAllocator: allocation after freeze");

        // NASA Power of 10 Rule 5: Assert valid allocation size
        assert.assert(len > 0, "FrozenAllocator: allocation size must be greater than zero");

        // Convert alignment enum to byte units (e.g., Alignment.@"8" -> 8)
        const alignment_bytes = ptr_align.toByteUnits();
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment_bytes);
        const new_offset = aligned_offset + len;

        if (new_offset > self.buffer.len) {
            return null; // Out of memory
        }

        self.offset = new_offset;
        return self.buffer[aligned_offset..].ptr;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_size: usize,
        ret_addr: usize,
    ) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_size;
        _ = ret_addr;

        // No resize support - return false to force alloc
        return false;
    }

    fn remap(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_size: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_size;
        _ = ret_addr;

        // No remap support - return null to force alloc + copy + free
        return null;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // No-op: we don't support freeing in frozen mode
    }
};

/// Static buffer size for init allocations.
/// 128KB should be plenty for config loading, WAL replay, etc.
/// Buffer is aligned to 16 bytes to satisfy dir.walk() and similar functions.
pub const init_allocator_size: usize = 128 * 1024;
pub const init_allocator_align: usize = 16;

/// Initialize a new frozen allocator with a stack-allocated buffer.
/// The buffer lives in the caller's stack frame - the returned allocator
/// must be stored by the caller to keep the buffer valid.
/// The buffer is aligned to 16 bytes to satisfy alignment requirements.
pub fn init() FrozenAllocator {
    var buffer: [init_allocator_size]u8 align(init_allocator_align) = undefined;
    return FrozenAllocator.init(&buffer);
}
