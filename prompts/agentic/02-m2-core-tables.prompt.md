# Mission Prompt — M2 Core Tables (No Side Effects)

You are an implementation agent.

## Mission
Implement fixed-capacity core tables for NodeMeta, JobSpecSummary, Placement.

## Required outputs
- Deterministic insert/update/delete behavior.
- Dirty tracking hooks per table.
- Overflow signaling (never silent drop without signal).
- Unit tests for normal and full-capacity cases.

## Constraints
- No runtime heap allocation in hot paths.
- No I/O in core table code.
- Stable iteration order must be documented.

## Acceptance criteria
- Tests pass for:
  - insert/update/delete
  - table full behavior
  - deterministic order
- Core compiles cleanly.
- Touched files are limited to core + tests.

## Completion report format
- Files changed
- Test commands + results
- Any perf/memory notes
