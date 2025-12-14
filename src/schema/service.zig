const std = @import("std");

/// The Definition of a Workload.
/// Must fit inside Packet.payload (920 bytes).
pub const Service = extern struct {
    /// Unique deployment ID (e.g., hash of the flake input).
    id: u64,
    
    /// Service Name (e.g., "web-server").
    /// Fixed 32 bytes. Zero-padded.
    name: [32]u8,
    
    /// The Nix Flake URI (e.g., "github:user/repo#app").
    /// Fixed 128 bytes.
    flake_uri: [128]u8,
    
    /// The binary to run (relative to flake result/bin/).
    /// e.g., "my-app".
    exec_name: [32]u8,

    /// Helpers to set/get strings comfortably.
    pub fn setName(self: *Service, slice: []const u8) void {
        @memset(&self.name, 0);
        const len = @min(slice.len, self.name.len);
        @memcpy(self.name[0..len], slice[0..len]);
    }

    pub fn getName(self: *const Service) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    
    pub fn setFlake(self: *Service, slice: []const u8) void {
        @memset(&self.flake_uri, 0);
        const len = @min(slice.len, self.flake_uri.len);
        @memcpy(self.flake_uri[0..len], slice[0..len]);
    }

    pub fn getFlake(self: *const Service) []const u8 {
        return std.mem.sliceTo(&self.flake_uri, 0);
    }
};

comptime {
    if (@sizeOf(Service) > 920) {
        @compileError("Service struct is too fat for the Packet payload!");
    }
}
