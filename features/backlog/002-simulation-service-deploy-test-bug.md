# Issue: Simulation Test Has Wrong Assertion

## Summary
The `service_deploy` simulation test deploys a service but then asserts that there are 0 services in the world.

## Severity
**HIGH** - This is a bug in the test suite that gives false confidence.

## Location
- File: `tests/simulation.zig`
- Function: `test "Simulation: service_deploy scenario"` (lines 646-653)

## Current Behavior
```zig
test "Simulation: service_deploy scenario" {
    var sim = Simulation.init(.{});
    const scenario = scenarioServiceDeploy();

    try sim.run(scenario, testing.allocator);

    // BUG: Deploys a service but expects 0
    try testing.expectEqual(@as(usize, 0), sim.world.service_count);
}
```

The scenario `scenarioServiceDeploy()` explicitly deploys a service with 2 replicas, but the test asserts `service_count == 0`.

## Expected Behavior
The test should expect `service_count == 1` since the scenario deploys one service.

## How to Fix
Change line 652 from:
```zig
try testing.expectEqual(@as(usize, 0), sim.world.service_count);
```
to:
```zig
try testing.expectEqual(@as(usize, 1), sim.world.service_count);
```

Or add additional assertions to verify the service has the correct properties (name="nginx", replicas=2).

## Relevant Code
- `tests/simulation.zig` - `scenarioServiceDeploy()` function (lines 361-409) shows what the scenario does
- `src/core/reducer.zig` - reducer logic that processes service_deploy events

## Verification
After the fix, run:
```bash
zig build test
```
