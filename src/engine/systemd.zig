const std = @import("std");
const Service = @import("../schema/service.zig").Service;

/// Generates a Systemd Unit file content.
/// Writes the result into 'out_buffer'.
pub fn compile(service: Service, out_buffer: []u8) ![]u8 {
    // Constitutional Defaults
    // 1. DynamicUser=yes (Ephemeral UID)
    // 2. ProtectSystem=strict (Read-only /)
    // 3. OOMScoreAdjust=500 (Kill this before the daemon)
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
        \\# The actual binary path is resolved by Nix in Phase 4.2
        \\ExecStart=/var/lib/myco/bin/{d}/{s}
        \\
        \\[Install]
        \\WantedBy=multi-user.target
    ;

    return std.fmt.bufPrint(out_buffer, template, .{
        service.getName(),
        service.id,
        std.mem.sliceTo(&service.exec_name, 0),
    });
}
