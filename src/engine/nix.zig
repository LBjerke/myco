// Thin wrapper around invoking Nix builds for service artifacts (no alloc).
// This file provides a thin, allocation-free wrapper for invoking Nix builds.
// It defines the `NixBuilder` struct, which is responsible for constructing
// and executing Nix commands (e.g., `nix build`) to generate service artifacts.
// This module is a crucial part of Myco's deployment engine, enabling the
// integration of Nix as the primary build system for managing services.
//
const std = @import("std");
const limits = @import("../core/limits.zig");
const proc = @import("../util/process_noalloc.zig");

pub const NixBuilder = struct {
    cmd_buf: [limits.MAX_LOG_LINE]u8 = undefined,

    /// Create a builder.
    pub fn init() NixBuilder {
        return .{ .cmd_buf = undefined };
    }

    /// Constructs and runs the Nix build command.
    /// Command: nice -n 19 nix build {flake_uri} --out-link {out_path}
    /// Returns the out_path on success (or a formatted command string in dry_run).
    pub fn build(self: *NixBuilder, flake_uri: []const u8, out_path: []const u8, dry_run: bool) ![]const u8 {
        if (dry_run) {
            const cmd = try std.fmt.bufPrint(&self.cmd_buf, "nice -n 19 nix build {s} --out-link {s}", .{ flake_uri, out_path });
            return cmd;
        }

        var flake_buf: [limits.MAX_FLAKE_URI + 1]u8 = undefined;
        var out_buf: [limits.PATH_MAX + 1]u8 = undefined;
        const flake_z = try proc.toZ(flake_uri, &flake_buf);
        const out_z = try proc.toZ(out_path, &out_buf);

        const nice_z: [:0]const u8 = "nice";
        const dashn_z: [:0]const u8 = "-n";
        const prio_z: [:0]const u8 = "19";
        const nix_z: [:0]const u8 = "nix";
        const build_z: [:0]const u8 = "build";
        const outlink_z: [:0]const u8 = "--out-link";
        const argv = [_:null]?[*:0]const u8{
            nice_z.ptr,
            dashn_z.ptr,
            prio_z.ptr,
            nix_z.ptr,
            build_z.ptr,
            flake_z,
            outlink_z.ptr,
            out_z,
            null,
        };

        try proc.spawnAndWait(&argv);
        return out_path;
    }
};

test "NixBuilder: dry run returns full command string" {
    var builder = NixBuilder.init();
    const cmd = try builder.build("flake-uri", "/tmp/out", true);

    try std.testing.expect(std.mem.containsAtLeast(u8, cmd, 1, "nix build"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cmd, 1, "/tmp/out"));
    try std.testing.expect(std.mem.containsAtLeast(u8, cmd, 1, "nice -n 19"));
}
