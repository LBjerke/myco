// This file contains a basic unit test for the `Orchestrator` module.
// The primary purpose of this test is to verify that the `Orchestrator`
// is correctly initialized and that its internal `ux` (User Experience)
// pointer is properly wired, thereby ensuring that the orchestrator has
// functional access to the UX helpers for logging and feedback during
// its operational lifecycle.
//
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
