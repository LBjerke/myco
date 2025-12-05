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
    pub fn nixosRebuild(self: *const Nix) !void {
        //runs nixos rebuild switch

        if (self.proprietary_software == true) {
            const argv = [_][]const u8{ "nixos-rebuild", "switch", "--flake", ".#loki", "--impure" };
            var env_map = runner.EnvMap.init(self.allocator);
            try env_map.put("NIXPKGS_ALLOW_UNFREE", "1");
            defer env_map.deinit();
            var new_nixos_config = runner.Child.init(&argv, self.allocator);
            new_nixos_config.cwd = "/etc/nixos";
            new_nixos_config.env_map = &env_map;
            _ = try runner.Child.spawnAndWait(&new_nixos_config);
        } else {
            const argv = [_][]const u8{ "nixos-rebuild", "switch", "--flake", ".#loki" };
            var new_nixos_config = runner.Child.init(&argv, self.allocator);
            new_nixos_config.cwd = "/etc/nixos";
            _ = try runner.Child.spawnAndWait(&new_nixos_config);
        }
    }
};
