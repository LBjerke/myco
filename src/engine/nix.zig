const std = @import("std");

pub const NixBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NixBuilder {
        return .{ .allocator = allocator };
    }

    /// Constructs and runs the Nix build command.
    /// 
    /// Command: nice -n 19 nix build {flake_uri} --out-link {out_path}
    /// 
    /// If dry_run is true, it returns the command string instead of executing.
    pub fn build(self: *NixBuilder, flake_uri: []const u8, out_path: []const u8, dry_run: bool) !?[]u8 {
        // The arguments for the OS process
        const argv = [_][]const u8{
            "nice", "-n", "19",  // Low CPU priority (Background)
            "nix", "build",
            flake_uri,
            "--out-link", out_path,
        };

        if (dry_run) {
            // Join arguments for verification in tests
            // FIX: We use 'try' to handle the allocation error immediately.
            // This leaves us with a []u8, which strictly coerces to ?[]u8.
            const cmd = try std.mem.join(self.allocator, " ", &argv);
            return cmd;
        }

        // REAL EXECUTION (Phase 4 Production Logic)
        // We use std.process.Child to spawn the build.
        var child = std.process.Child.init(&argv, self.allocator);
        
        // We ignore stdout/stderr for now (or could log to a file)
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const term = try child.spawnAndWait();
        
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.NixBuildFailed;
            },
            else => return error.NixProcessCrashed,
        }

        return null;
    }
};
