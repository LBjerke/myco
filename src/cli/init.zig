// CLI scaffolding: generates initial flake and config files for a new Myco project.
const std = @import("std");
const templates = @import("templates.zig");

pub const Scaffolder = struct {
    /// The directory where files will be generated.
    /// In prod: std.fs.cwd()
    /// In tests: tmp_dir
    target_dir: std.fs.Dir,

    pub fn init(dir: std.fs.Dir) Scaffolder {
        return .{ .target_dir = dir };
    }

    /// Generates the starter files.
    /// Returns error.PathAlreadyExists if files overwrite existing work.
    pub fn generate(self: Scaffolder) !void {
        try self.writeAtomic("flake.nix", templates.FLAKE_NIX);
        try self.writeAtomic("myco.json", templates.MYCO_JSON);
    }

    fn writeAtomic(self: Scaffolder, filename: []const u8, content: []const u8) !void {
        // Atomic Create: Fails if file exists.
        const file = try self.target_dir.createFile(filename, .{ .exclusive = true });
        defer file.close();

        try file.writeAll(content);
    }
};
