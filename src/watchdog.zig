const std = @import("std");

/// The Watchdog Thread
/// It wakes up every (Interval / 2) and yells "WATCHDOG=1" at Systemd.
pub const Watchdog = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    interval_us: u64,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) !?Watchdog {
        // 1. Check if we are running under Systemd with Watchdog enabled
        // Systemd sets WATCHDOG_USEC to the timeout in microseconds.
        const timeout_env = std.posix.getenv("WATCHDOG_USEC") orelse return null;
        const socket_env = std.posix.getenv("NOTIFY_SOCKET") orelse return null;

        const timeout_us = try std.fmt.parseInt(u64, timeout_env, 10);

        // We ping at half the timeout interval to be safe
        const interval = timeout_us / 2;

        return Watchdog{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_env),
            .interval_us = interval,
        };
    }

    pub fn deinit(self: *Watchdog) void {
        self.stop();
        self.allocator.free(self.socket_path);
    }

    pub fn start(self: *Watchdog) !void {
        if (self.running.load(.seq_cst)) return;
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Watchdog) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn loop(self: *Watchdog) void {
        // Create a Datagram socket to talk to Systemd
        const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0) catch return;
        defer std.posix.close(sock);

        // Construct Address
        // Handle Abstract Namespace (starts with @ in env, needs \x00 for syscall)
        var addr_buf = std.net.Address.initUnix(self.socket_path) catch return;

        // Connect once (optimization)
        std.posix.connect(sock, &addr_buf.any, addr_buf.getOsSockLen()) catch return;

        while (self.running.load(.seq_cst)) {
            // Send the signal
            _ = std.posix.write(sock, "WATCHDOG=1") catch {};

            // Sleep
            // interval is microseconds, sleep expects nanoseconds
            std.Thread.sleep(self.interval_us * 1000);
        }
    }

    /// Send "READY=1" to tell Systemd we finished initialization
    pub fn notifyReady(self: *Watchdog) void {
        const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0) catch return;
        defer std.posix.close(sock);
        var addr = std.net.Address.initUnix(self.socket_path) catch return;
        std.posix.connect(sock, &addr.any, addr.getOsSockLen()) catch return;
        _ = std.posix.write(sock, "READY=1") catch {};
    }
};
