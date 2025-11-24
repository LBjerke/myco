const std = @import("std");
const runner = std.process;

pub const Nix = struct {
    allocator: std.mem.Allocator,
    proprietary_software: bool,
    flakes: bool,

    pub fn init(allocator: std.mem.Allocator) Nix {
        return Nix{ .allocator = allocator, .flakes = false, .proprietary_software = false };
    }

    pub fn nixosRebuild(self: *const Nix) !void {
        //runs nixos rebuild switch

        if (self.proprietary_software == true) {
            const argv = [_][]const u8{ "nixos-rebuild", "switch", "--flake", ".#loki", "--impure" };
            var env_map = runner.EnvMap.init(self.allocator);
            try env_map.put("NIXPKGS_ALLOW_UNFREE", "1");
            defer env_map.deinit();
            var up = runner.Child.init(&argv, self.allocator);
            up.cwd = "/etc/nixos";
            up.env_map = &env_map;
            _ = try runner.Child.spawnAndWait(&up);
        } else {
            const argv = [_][]const u8{ "nixos-rebuild", "switch", "--flake", ".#loki" };
            var up = runner.Child.init(&argv, self.allocator);
            up.cwd = "/etc/nixos";
            _ = try runner.Child.spawnAndWait(&up);
        }
    }
};
