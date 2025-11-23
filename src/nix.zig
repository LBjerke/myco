const std = @import("std");

pub const Nix = struct {
    cwd: []const u8,
    env_variables: []const u8,
    pub fn init(cwd: []const u8, env_variables: []const u8) Nix {
        return Nix{ .cwd = cwd, .env_variables = env_variables };
    }

    pub fn nixosRebuild(self: *const Nix) !void {
        //runs nixos rebuild switch
        std.debug.print("All your database {s} are belong to us.\n", .{self.cwd});
        std.debug.print("All your database {s} are belong to us.\n", .{self.env_variables});
    }
};
