const std = @import("std");
const Nix = @import("../infra/nix.zig");
const Systemd = @import("../infra/systemd.zig");
const Config = @import("config.zig");
const UX = @import("../util/ux.zig").UX;

pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    ux: *UX,

    pub fn init(allocator: std.mem.Allocator, ux: *UX) Orchestrator {
        return .{ .allocator = allocator, .ux = ux };
    }

    /// The standardized workflow to deploy a service
    pub fn reconcile(self: *Orchestrator, svc: Config.ServiceConfig) !void {
        // 1. Build
        // We use catch/return here to avoid crashing the whole loop/thread on one failure
        try self.ux.step("Building {s} ({s})", .{svc.name, svc.package});
        
        var nix_new = Nix.Nix.init(self.allocator);
        const store_path = nix_new.build( svc.package) catch |err| {
            self.ux.fail("Build failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(store_path);
        
        self.ux.success("Built {s}", .{svc.name});

        // 2. Apply
        try self.ux.step("Starting {s}", .{svc.name});
        
        Systemd.apply(self.allocator, svc, store_path) catch |err| {
            self.ux.fail("Start failed: {}", .{err});
            return err;
        };
        
        self.ux.success("{s} is running!", .{svc.name});
    }
};
