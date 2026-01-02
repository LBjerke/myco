// This file contains unit tests for the `myco.engine.systemd` module,
// specifically verifying the correct generation of systemd unit file content.
// This test ensures that the `compile` function accurately incorporates the
// service's `id` and `exec_name` into the `ExecStart` directive of the
// generated systemd unit, thereby confirming proper integration with the
// systemd service management.
//
const std = @import("std");
const myco = @import("myco");
const systemd = myco.engine.systemd;
const Service = myco.schema.service.Service;

test "systemd: compile uses exec_name and id in ExecStart" {
    var service = Service{
        .id = 42,
        .name = undefined,
        .flake_uri = undefined,
        .exec_name = undefined,
    };
    service.setName("demo");
    service.setFlake("flake");
    const exec = "app";
    @memcpy(service.exec_name[0..exec.len], exec);

    var buf: [512]u8 = undefined;
    const unit = try systemd.compile(service, &buf);

    try std.testing.expect(std.mem.containsAtLeast(u8, unit, 1, "ExecStart=/var/lib/myco/bin/42/result/bin/app"));
}
