// High-level deploy workflow: build with Nix, generate systemd unit, and start service.
const std = @import("std");
const Nix = @import("../engine/nix.zig");
const Systemd = @import("../engine/systemd.zig");
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
        if (std.posix.getenv("MYCO_SMOKE_SKIP_EXEC") != null) {
            self.ux.success("Smoke mode: skipping deploy for {s}", .{svc.name});
            return;
        }

        try self.ux.step("Building {s} ({s})", .{ svc.name, svc.package });

        var out_buf: [256]u8 = undefined;
        const out_link = try std.fmt.bufPrint(&out_buf, "/var/lib/myco/bin/{s}/result", .{svc.name});

        var nix_new = Nix.NixBuilder.init(self.allocator);
        const store_path = nix_new.build(svc.package, out_link, false) catch |err| {
            self.ux.fail("Build failed: {}", .{err});
            return err;
        };
        self.ux.success("Built {s}", .{svc.name});

        try self.ux.step("Starting {s}", .{svc.name});

        Systemd.apply(self.allocator, svc, store_path) catch |err| {
            self.ux.fail("Start failed: {}", .{err});
            return err;
        };

        self.ux.success("{s} is running!", .{svc.name});
    }
};
