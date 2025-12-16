// Generates systemd unit files for deployed services.
const std = @import("std");
const Service = @import("../schema/service.zig").Service;

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
