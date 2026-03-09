# Feature: Fix Simulation Service Deploy Test

**Status**: ✅ Complete

## Original Ask

Fix the `service_deploy` simulation test in `tests/simulation.zig` - it was asserting that there are 0 services in the world after running a scenario that explicitly deploys a service.

## Why This Matters

This was a bug in the test suite that gave **false confidence**:
- The test was passing even though it was testing the wrong thing
- It would not catch regressions in the service deployment functionality
- The scenario clearly shows a service being deployed with 2 replicas

## Problem Identified

In `tests/simulation.zig`, line 652:
```zig
try testing.expectEqual(@as(usize, 0), sim.world.service_count);
```

But the `scenarioServiceDeploy()` function clearly shows:
1. Three nodes joining (lines 367-369)
2. A service being deployed with `service_id = 1`, name = "nginx", replicas = 2 (lines 371-377)
3. A verify step that expects `expected_services = 1` (line 383)

The test should expect `service_count == 1`, not 0.

## How It Was Solved

Changed line 652 from:
```zig
try testing.expectEqual(@as(usize, 0), sim.world.service_count);
```
to:
```zig
try testing.expectEqual(@as(usize, 1), sim.world.service_count);
```

Also added a comment to explain what the scenario does.

## Testing

All tests pass:
```
zig build test
# Exit code: 0
```

## Learnings & Troubleshooting

This was a simple logic error where the test assertion didn't match the scenario being tested. The scenario itself had the correct expectation (`expected_services = 1` in the verify step), but the final test assertion was wrong.

**Prevention**: This kind of bug can be prevented by:
- Having tests verify the actual scenario expectations
- Running the scenario's built-in verify steps
- Adding comments explaining what the test is checking
