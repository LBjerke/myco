// Thin wrapper around invoking Nix builds for service artifacts.
const std = @import("std");

pub const NixBuilder = struct {
    allocator: std.mem.Allocator,

    /// Create a builder bound to an allocator.
    pub fn init(allocator: std.mem.Allocator) NixBuilder {
        return .{ .allocator = allocator };
    }

    /// Constructs and runs the Nix build command.
    /// Command: nice -n 19 nix build {flake_uri} --out-link {out_path}
    /// Returns the out_path on success.
    pub fn build(self: *NixBuilder, flake_uri: []const u8, out_path: []const u8, dry_run: bool) ![]const u8 {
        const argv = [_][]const u8{
            "nice", "-n", "19",
            "nix", "build",
            flake_uri,
            "--out-link", out_path,
        };

        if (dry_run) {
            const cmd = try std.mem.join(self.allocator, " ", &argv);
            return cmd;
        }

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.NixBuildFailed;
            },
            else => return error.NixProcessCrashed,
        }

        return out_path;
    }
};
