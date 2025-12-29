const std = @import("std");
const myco = @import("myco");
const Orchestrator = myco.core.orchestrator.Orchestrator;
const UX = myco.util.ux.UX;

test "Orchestrator: init wires ux pointer" {
    var ux = UX.init();
    defer ux.deinit();

    const orch = Orchestrator.init(&ux);
    try std.testing.expect(orch.ux == &ux);
}
