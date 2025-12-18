// Generates systemd unit files for deployed services.
const std = @import("std");
const Service = @import("../schema/service.zig").Service;
const Config = @import("../core/config.zig").ServiceConfig;

/// Generates a Systemd Unit file content.
/// Writes the result into 'out_buffer'.
pub fn compile(service: Service, out_buffer: []u8) ![]u8 {
    // Constitutional Defaults
    // 1. DynamicUser=yes (Ephemeral UID)
    // 2. ProtectSystem=strict (Read-only /)
    // 3. OOMScoreAdjust=500 (Kill this before the daemon)
    // ... inside compile() function ...
    
    // FIX: Updated path to match Nix layout
    // ExecStart=/var/lib/myco/bin/{id}/result/bin/{exec_name}

        const template =
        \\[Unit]
        \\Description=Myco Managed Service: {s}
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\DynamicUser=yes
        \\ProtectSystem=strict
        \\ProtectHome=yes
        \\NoNewPrivileges=yes
        \\TasksMax=100
        \\OOMScoreAdjust=500
        \\
        \\# Nix builds create a 'result' symlink. The binary is inside 'bin/'.
        \\ExecStart=/var/lib/myco/bin/{d}/result/bin/{s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    ;
// ...
    return std.fmt.bufPrint(out_buffer, template, .{
        service.getName(),
        service.id,
        std.mem.sliceTo(&service.exec_name, 0),
    });
}

/// Minimal apply: write a unit file pointing to the built path. No systemctl integration here.
pub fn apply(allocator: std.mem.Allocator, cfg: Config, store_path: []const u8) !void {
    std.fs.cwd().makePath("/run/systemd/system") catch {};
    const unit_path = try std.fmt.allocPrint(allocator, "/run/systemd/system/myco-{s}.service", .{cfg.name});
    defer allocator.free(unit_path);

    var buf: [2048]u8 = undefined;
    const exec_name = if (cfg.cmd) |c| c else cfg.name;
    const unit_content = try std.fmt.bufPrint(&buf,
        \\[Unit]
        \\Description=Myco Managed Service: {s}
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s}/bin/{s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    , .{cfg.name, store_path, exec_name});

    const file = try std.fs.cwd().createFile(unit_path, .{});
    defer file.close();
    try file.writeAll(unit_content);
}
