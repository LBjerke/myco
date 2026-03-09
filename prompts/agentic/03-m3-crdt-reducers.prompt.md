# Mission Prompt — M3 CRDT + Reducers

You are an implementation agent.

## Mission
Implement HLC, CRDT merge semantics, and reducer entrypoints.

## Required outputs
- HLC functions: next, observe, compare.
- LWW merges for replicated components.
- Placement merge order: epoch > HLC > score > node_id.
- Entry points: applyProposal, mergeDelta, tick.
- Tests for ordering and deterministic replay outcomes.

## Constraints
- Reducers must be side-effect free.
- No external I/O calls.
- Tie-break behavior must be explicit and tested.

## Acceptance criteria
- Replay of same events in varying arrival order converges.
- Merge edge cases documented.
- All new tests pass.

## Completion report format
- Files changed
- Merge rules implemented
- Property/edge tests added
