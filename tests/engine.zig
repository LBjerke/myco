// Engine unit tests: verify Nix command construction and systemd unit generation.
const std = @import("std");
const myco = @import("myco");
const Service = myco.schema.service.Service;
const systemd = myco.engine.systemd;
const NixBuilder = myco.engine.nix.NixBuilder;

test "Phase 4: Nix Build Command Construction" {
    const allocator = std.testing.allocator;
    var builder = NixBuilder.init(allocator);

    const flake = "github:myco/web#app";
    const out = "/var/lib/myco/bin/123";

    // Perform Dry Run
    const cmd_string = try builder.build(flake, out, true); // true = dry_run
    defer allocator.free(cmd_string.?);

    std.debug.print("\n--- GENERATED NIX CMD ---\n{s}\n-------------------------\n", .{cmd_string.?});

    // ASSERTIONS
    // 1. Check Priority (nice -n 19)
    try std.testing.expect(std.mem.startsWith(u8, cmd_string.?, "nice -n 19 nix build"));
    
    // 2. Check Arguments
    try std.testing.expect(std.mem.indexOf(u8, cmd_string.?, flake) != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd_string.?, out) != null);
}

test "Phase 4: Systemd Compilation Compliance" {
    var service = Service{
        .id = 12345,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };
    service.setName("nginx-proxy");
    service.setFlake("github:myco/proxy");
    
    // Set exec name properly
    @memset(&service.exec_name, 0);
    const exec = "nginx";
    @memcpy(service.exec_name[0..exec.len], exec);

    var buffer: [2048]u8 = undefined;
    const unit_file = try systemd.compile(service, &buffer);

    // DEBUG: Print it so we can see it
    std.debug.print("\n--- GENERATED UNIT FILE ---\n{s}\n---------------------------\n", .{unit_file});

    // ASSERTIONS
    // Check for Security Defaults
    try std.testing.expect(std.mem.indexOf(u8, unit_file, "DynamicUser=yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit_file, "ProtectSystem=strict") != null);
    
    // Check for Correct Data
    try std.testing.expect(std.mem.indexOf(u8, unit_file, "Description=Myco Managed Service: nginx-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit_file, "ExecStart=/var/lib/myco/bin/12345/nginx") != null);
}
