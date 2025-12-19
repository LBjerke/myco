const std = @import("std");
const myco = @import("myco");
const Orchestrator = myco.core.orchestrator.Orchestrator;
const UX = myco.util.ux.UX;

test "Orchestrator: init wires allocator and ux pointer" {
    const allocator = std.testing.allocator;
    var ux = UX.init(allocator);
    defer ux.deinit();

    const orch = Orchestrator.init(allocator, &ux);
    try std.testing.expectEqual(allocator, orch.allocator);
    try std.testing.expect(orch.ux == &ux);
}
