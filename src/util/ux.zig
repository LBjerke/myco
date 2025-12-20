// CLI UX helpers: logging, spinners, prompts without extra UI deps.
const std = @import("std");

/// The User Experience Module
pub const UX = struct {
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    is_tty: bool,

    spinner_thread: ?std.Thread = null,
    spinner_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    current_msg: ?[]const u8 = null,
    current_buf: [256]u8 = undefined,
    current_len: usize = 0,

    const Color = enum { reset, red, green, yellow, blue, bold, dim };
    pub fn log(self: *UX, comptime fmt: []const u8, args: anytype) void {
        // Stop spinner momentarily to avoid tearing if active
        // (In a TUI we would print to a specific area, for CLI we just print a line)

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        // Format: [INFO] Message
        // We use printRaw which writes to the handle safely
        // Gray/Dim color for background logs to distinguish from user actions
        self.printRaw("{s}[INFO]{s} {s}\n", .{ self.color(.dim), self.color(.reset), msg });
    }

    pub fn init(allocator: std.mem.Allocator) UX {
        // Use the standard getter. In Zig it returns a File struct.
        // We will interact with it via .writeAll (direct syscall), not .writer() (abstraction)
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

        // Check TTY on that handle

        const is_tty = std.posix.isatty(stdout.handle);

        return UX{
            .allocator = allocator,
            .stdout = stdout,
            .is_tty = is_tty,
        };
    }

    pub fn deinit(self: *UX) void {
        self.stopSpinner();
        self.current_msg = null;
        self.current_len = 0;
    }

    // --- Core Printing Logic ---

    fn color(self: *UX, c: Color) []const u8 {
        if (!self.is_tty) return "";
        return switch (c) {
            .reset => "\x1b[0m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
        };
    }

    fn printRaw(self: *UX, comptime fmt: []const u8, args: anytype) void {
        // We fall back to std.debug.print if allocation fails, so we can see the error
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
            std.debug.print("UX ALLOC ERROR: {}\n", .{err});
            return;
        };

        self.stdout.writeAll(msg) catch |err| {
            std.debug.print("UX WRITE ERROR: {}\n", .{err});
        };
    }

    // --- Public API ---

    pub fn step(self: *UX, comptime fmt: []const u8, args: anytype) !void {
        self.stopSpinner();

        self.current_msg = null;
        const current = try std.fmt.bufPrint(&self.current_buf, fmt, args);
        self.current_len = current.len;
        self.current_msg = self.current_buf[0..self.current_len];

        self.printRaw("{s}[*]{s} {s}...", .{ self.color(.blue), self.color(.reset), current });

        self.startSpinner();
    }

    pub fn success(self: *UX, comptime fmt: []const u8, args: anytype) void {
        self.stopSpinner();
        self.clearLine();

        self.printRaw("{s}[+]{s} ", .{ self.color(.green), self.color(.reset) });
        self.printRaw(fmt, args);
        self.printRaw("\n", .{});
    }

    pub fn fail(self: *UX, comptime fmt: []const u8, args: anytype) void {
        self.stopSpinner();
        self.clearLine();

        self.printRaw("{s}[x]{s} ", .{ self.color(.red), self.color(.reset) });
        self.printRaw(fmt, args);
        self.printRaw("\n", .{});
    }

    // --- Animation Logic ---

    fn clearLine(self: *UX) void {
        if (self.is_tty) {
            // ANSI: Clear entire line (2K) + Carriage Return (\r)
            self.printRaw("\x1b[2K\r", .{});
        } else {
            // In non-TTY logs, just print a newline so the next log is on a new line
            self.printRaw("\n", .{});
        }
    }

    fn startSpinner(self: *UX) void {
        if (!self.is_tty) return;
        self.spinner_running.store(true, .seq_cst);
        self.spinner_thread = std.Thread.spawn(.{}, spinnerLoop, .{self}) catch null;
    }

    fn stopSpinner(self: *UX) void {
        if (!self.spinner_running.load(.seq_cst)) return;

        self.spinner_running.store(false, .seq_cst);
        if (self.spinner_thread) |t| {
            t.join();
            self.spinner_thread = null;
        }
        self.clearLine();
    }

    fn spinnerLoop(self: *UX) void {
        const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
        var idx: usize = 0;

        while (self.spinner_running.load(.seq_cst)) {
            var buf: [16]u8 = undefined;
            // ANSI: Space + Char + Backspace x 2
            // This prints the spinner at the cursor position
            if (std.fmt.bufPrint(&buf, " {c}\x1b[2D", .{frames[idx]})) |s| {
                _ = self.stdout.write(s) catch {};
            } else |_| {}

            idx = (idx + 1) % frames.len;
            std.Thread.sleep(100 * 1_000_000);
        }
    }
    // --- Input Logic (Added) ---

    pub fn prompt(self: *UX, comptime fmt: []const u8, args: anytype, buffer: []u8) ![]const u8 {
        self.stopSpinner(); // Ensure spinner is off while waiting for input

        // Print the Question
        self.printRaw("{s}[?]{s} ", .{ self.color(.yellow), self.color(.reset) });
        self.printRaw(fmt, args);
        self.printRaw(": ", .{});

        // Read Stdin directly via POSIX handle to avoid std.io issues
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };

        // Read into buffer
        const bytes_read = try stdin.read(buffer);
        if (bytes_read == 0) return "";

        // Slice the valid data
        const line = buffer[0..bytes_read];

        // Trim newline characters (\n or \r\n)
        return std.mem.trimRight(u8, line, "\n\r");
    }
};

test "UX: step/success/fail without TTY does not spawn spinner" {
    const allocator = std.testing.allocator;
    var ux = UX{
        .allocator = allocator,
        .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
        .is_tty = false, // avoid spinner thread creation
        .spinner_thread = null,
        .spinner_running = std.atomic.Value(bool).init(false),
        .current_msg = null,
    };
    defer ux.deinit();

    try ux.step("hello {s}", .{"world"});
    try std.testing.expect(ux.current_msg != null);

    ux.success("ok", .{});
    ux.fail("warn {d}", .{1});
}
