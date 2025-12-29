// High-level deploy workflow: build with Nix, generate systemd unit, and start service.
const std = @import("std");
const myco = @import("myco");
const limits = @import("../core/limits.zig");
const Nix = myco.engine.nix;
const Systemd = myco.engine.systemd;
const Config = myco.core.config;
const UX = myco.util.ux.UX;
const noalloc_guard = myco.util.noalloc_guard;

pub const Orchestrator = struct {
    ux: *UX,

    pub fn init(ux: *UX) Orchestrator {
        return .{ .ux = ux };
    }

    /// The standardized workflow to deploy a service
    pub fn reconcile(self: *Orchestrator, svc: Config.ServiceConfig) !void {
        noalloc_guard.check();
        try self.ux.step("Building {s} ({s})", .{ svc.name, svc.package });

        var out_link_buf: [limits.PATH_MAX]u8 = undefined;
        const out_link = try std.fmt.bufPrint(&out_link_buf, "/var/lib/myco/bin/{s}/result", .{svc.name});

        var nix_new = Nix.NixBuilder.init();
        const store_path = nix_new.build(svc.package, out_link, false) catch |err| {
            self.ux.fail("Build failed: {}", .{err});
            return err;
        };
        self.ux.success("Built {s}", .{svc.name});

        try self.ux.step("Starting {s}", .{svc.name});

        Systemd.apply(svc, store_path) catch |err| {
            self.ux.fail("Start failed: {}", .{err});
            return err;
        };

        self.ux.success("{s} is running!", .{svc.name});
    }
};
