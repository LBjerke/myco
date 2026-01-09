const std = @import("std");
const myco = @import("myco"); // Import myco module for Node, Service, Limits etc.

const Limits = myco.limits;
const Node = myco.Node;
const Service = myco.schema.service.Service;
const SystemdCompiler = myco.engine.systemd;
const NixBuilder = myco.engine.nix.NixBuilder;
const proc_noalloc = myco.util.process_noalloc;

pub const DaemonContext = struct {
    nix_builder: NixBuilder,
};

/// Executor invoked on service deploys: builds via Nix and (re)starts a systemd unit.
pub fn realExecutor(ctx_ptr: *anyopaque, service: myco.schema.service.Service) anyerror!void {
    const ctx: *DaemonContext = @ptrCast(@alignCast(ctx_ptr));

    std.debug.print("⚙️ [Executor] Deploying Service: {s} (ID: {d})\n", .{ service.getName(), service.id });

    // 1. Prepare Paths
    var bin_dir_buf: [Limits.PATH_MAX]u8 = undefined;
    const bin_dir = try std.fmt.bufPrint(&bin_dir_buf, "/var/lib/myco/bin/{d}", .{service.id});

    // Recursive makePath to ensure parent dirs exist
    std.fs.cwd().makePath(bin_dir) catch {};

    // 2. Nix Build
    var out_link_buf: [Limits.PATH_MAX]u8 = undefined;
    const out_link = try std.fmt.bufPrint(&out_link_buf, "{s}/result", .{bin_dir});

    // Build the flake (using the NixBuilder wrapper)
    // false = real execution (not dry run)
    _ = try ctx.nix_builder.build(service.getFlake(), out_link, false);

    // 3. Systemd Unit Generation
    var unit_buf: [2048]u8 = undefined;
    const unit_content = try SystemdCompiler.compile(service, &unit_buf);

    // Use /run/systemd/system for ephemeral units on NixOS
    var unit_path_buf: [Limits.PATH_MAX]u8 = undefined;
    const unit_path = try std.fmt.bufPrint(&unit_path_buf, "/run/systemd/system/myco-{d}.service", .{service.id});

    // Write Unit File
    {
        const file = try std.fs.cwd().createFile(unit_path, .{});
        defer file.close();
        try file.writeAll(unit_content);
    }

    // 4. Reload and Start
    const systemctl_z: [:0]const u8 = "systemctl";
    const daemon_reload_z: [:0]const u8 = "daemon-reload";
    const daemon_reload = [_:null]?[*:0]const u8{ systemctl_z.ptr, daemon_reload_z.ptr, null };
    try proc_noalloc.spawnAndWait(&daemon_reload);

    var service_name_buf: [64]u8 = undefined;
    const service_name = try std.fmt.bufPrint(&service_name_buf, "myco-{d}", .{service.id});
    var service_name_z_buf: [64]u8 = undefined;
    const service_name_z = try proc_noalloc.toZ(service_name, &service_name_z_buf);

    const restart_z: [:0]const u8 = "restart";
    const start_cmd = [_:null]?[*:0]const u8{ systemctl_z.ptr, restart_z.ptr, service_name_z, null };
    try proc_noalloc.spawnAndWait(&start_cmd);

    std.debug.print("✅ [Executor] Service {s} is LIVE.\n", .{service.getName()});
}

pub fn noopExecutor(_: *anyopaque, _: myco.schema.service.Service) anyerror!void {}
