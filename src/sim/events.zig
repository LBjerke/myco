// Shared simulation event types for optional TUI/logging.
const std = @import("std");

pub const EventKind = enum {
    send,
    deliver,
    drop_loss,
    drop_congestion,
    drop_partition,
    drop_crypto,
};

pub const PacketEvent = struct {
    tick: u64,
    src: u16,
    dest: u16,
    msg_type: u8,
    kind: EventKind,
};

/// Fixed-size ring buffer of recent packet events.
pub const EventRing = struct {
    buffer: []PacketEvent,
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventRing {
        const buf = try allocator.alloc(PacketEvent, capacity);
        return .{ .buffer = buf };
    }

    pub fn deinit(self: *EventRing, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.buffer = &[_]PacketEvent{};
        self.next = 0;
        self.count = 0;
    }

    pub fn record(self: *EventRing, event: PacketEvent) void {
        if (self.buffer.len == 0) return;
        self.buffer[self.next] = event;
        self.next = (self.next + 1) % self.buffer.len;
        if (self.count < self.buffer.len) self.count += 1;
    }

    /// Copy up to out.len most recent events into `out` in chronological order.
    pub fn copyRecent(self: *const EventRing, out: []PacketEvent) usize {
        if (self.count == 0 or out.len == 0) return 0;
        const take = @min(self.count, out.len);
        var idx: usize = 0;
        // Oldest event index.
        const start = (self.next + self.buffer.len - self.count) % self.buffer.len;
        while (idx < take) : (idx += 1) {
            const src_idx = (start + idx) % self.buffer.len;
            out[idx] = self.buffer[src_idx];
        }
        return take;
    }
};
