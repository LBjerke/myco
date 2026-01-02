// Hybrid Logical Clock utilities used to order CRDT updates (last-write-wins).
// This file implements Hybrid Logical Clocks (HLCs), a critical component
// for ordering events and resolving conflicts in distributed systems like Myco.
// The `Hlc` struct combines a physical wall clock time with a logical counter,
// enabling a total ordering of events even in the presence of clock skew.
// This module provides functions to initialize, pack/unpack, compare, observe
// (merge with remote timestamps), and advance the clock, thereby ensuring
// consistent last-write-wins semantics for CRDT updates.
//
const std = @import("std");

pub const Hlc = struct {
    wall: u64,
    logical: u16,

    /// Create a clock anchored to the provided wall-clock milliseconds.
    pub fn init(now_ms: u64) Hlc {
        return .{ .wall = now_ms, .logical = 0 };
    }

    /// Convenience initializer using the current wall clock.
    pub fn initNow() Hlc {
        return init(currentMillis());
    }

    /// Return current wall-clock time in milliseconds.
    pub fn currentMillis() u64 {
        return @as(u64, @intCast(std.time.milliTimestamp()));
    }

    /// Pack wall (upper 48 bits) | logical (lower 16 bits) into a u64.
    pub fn pack(self: Hlc) u64 {
        return (self.wall << 16) | @as(u64, self.logical);
    }

    /// Unpack a u64 back into wall/logical components.
    pub fn unpack(v: u64) Hlc {
        return .{ .wall = v >> 16, .logical = @as(u16, @truncate(v)) };
    }

    /// True if `a` happened after `b` under HLC ordering.
    pub fn newer(a: Hlc, b: Hlc) bool {
        if (a.wall != b.wall) return a.wall > b.wall;
        return a.logical > b.logical;
    }

    /// Merge a remote timestamp into the local clock, returning the new packed value.
    pub fn observe(self: *Hlc, remote_packed: u64, now_ms: u64) u64 {
        const remote = Hlc.unpack(remote_packed);

        var max_wall = self.wall;
        if (remote.wall > max_wall) max_wall = remote.wall;
        if (now_ms > max_wall) max_wall = now_ms;

        if (max_wall == self.wall and max_wall == remote.wall) {
            const max_logical: u16 = if (self.logical > remote.logical) self.logical else remote.logical;
            self.logical = max_logical + 1;
        } else if (max_wall == self.wall) {
            self.logical += 1;
        } else if (max_wall == remote.wall) {
            self.logical = remote.logical + 1;
        } else {
            self.logical = 0;
        }

        self.wall = max_wall;
        return self.pack();
    }

    /// Merge a remote timestamp using the current wall clock.
    pub fn observeNow(self: *Hlc, remote_packed: u64) u64 {
        return self.observe(remote_packed, currentMillis());
    }

    /// Advance the clock for a local event, returning the packed timestamp.
    pub fn next(self: *Hlc, now_ms: u64) u64 {
        if (now_ms > self.wall) {
            self.wall = now_ms;
            self.logical = 0;
        } else {
            self.logical += 1;
        }
        return self.pack();
    }

    /// Advance using the current wall clock.
    pub fn nextNow(self: *Hlc) u64 {
        return self.next(currentMillis());
    }
};
