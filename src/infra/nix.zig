const std = @import("std");
const runner = std.process;

pub const Nix = struct {
    allocator: std.mem.Allocator,
    proprietary_software: bool,
    flakes: bool,

    pub fn init(allocator: std.mem.Allocator) Nix {
        return Nix{ .allocator = allocator, .flakes = false, .proprietary_software = false };
    }

    fn writeConfig() void {
        return;
    }
    pub fn serviceGenerator() void {
        return;
    }
    pub fn build(self: *const Nix, package: []const u8) ![]u8 {
        //runs nixos rebuild switch

        if (self.proprietary_software == true) {
            const argv = [_][]const u8{ "nix", "build", package, "--print-out-paths", "--no-link" };
            var env_map = runner.EnvMap.init(self.allocator);
            try env_map.put("NIXPKGS_ALLOW_UNFREE", "1");
            defer env_map.deinit();
            var new_nixos_config = runner.Child.init(&argv, self.allocator);
            new_nixos_config.env_map = &env_map;
            new_nixos_config.stdout_behavior = .Pipe;
            new_nixos_config.stderr_behavior = .Inherit;
            try new_nixos_config.spawn();

            // Read the output from the pipe
            // We set a max size (e.g., 1MB) to prevent memory exhaustion if something goes wrong
            const max_output_bytes = 1024 * 1024;
            const raw_output = try new_nixos_config.stdout.?.readToEndAlloc(self.allocator, max_output_bytes);
            errdefer self.allocator.free(raw_output); // Free memory if we error out later

            // Wait for the process to finish and check the exit code
            const term = try new_nixos_config.wait();

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.NixBuildFailed;
                    }
                },
                else => return error.ProcessCrashed,
            }

            // Nix adds a newline '\n' at the end. We must trim it.
            const trimmed = std.mem.trimRight(u8, raw_output, "\n\r");

            // We need to return a slice that fits the trimmed data.
            // Note: 'trimmed' is a slice of 'raw_output', so 'raw_output' owns the memory.
            // For this simple example, we return a duplicate of the trimmed string
            // so the caller owns clean memory, and we free the raw buffer.
            const final_path = try self.allocator.dupe(u8, trimmed);
            self.allocator.free(raw_output);

            return final_path;
        } else {
            const argv = [_][]const u8{ "nix", "build", package, "--print-out-paths", "--no-link" };
            var new_nixos_config = runner.Child.init(&argv, self.allocator);
            new_nixos_config.stdout_behavior = .Pipe;
            new_nixos_config.stderr_behavior = .Inherit;
            try new_nixos_config.spawn();

            // Read the output from the pipe
            // We set a max size (e.g., 1MB) to prevent memory exhaustion if something goes wrong
            const max_output_bytes = 1024 * 1024;
            const raw_output = try new_nixos_config.stdout.?.readToEndAlloc(self.allocator, max_output_bytes);
            errdefer self.allocator.free(raw_output); // Free memory if we error out later

            // Wait for the process to finish and check the exit code
            const term = try new_nixos_config.wait();

            switch (term) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.NixBuildFailed;
                    }
                },
                else => return error.ProcessCrashed,
            }

            // Nix adds a newline '\n' at the end. We must trim it.
            const trimmed = std.mem.trimRight(u8, raw_output, "\n\r");

            // We need to return a slice that fits the trimmed data.
            // Note: 'trimmed' is a slice of 'raw_output', so 'raw_output' owns the memory.
            // For this simple example, we return a duplicate of the trimmed string
            // so the caller owns clean memory, and we free the raw buffer.
            const final_path = try self.allocator.dupe(u8, trimmed);
            self.allocator.free(raw_output);

            return final_path;
        }
    }
};
