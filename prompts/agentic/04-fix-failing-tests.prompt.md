# Mission Prompt — Fix Failing Tests Only

You are a repair agent.

## Mission
Take current failing tests and make them pass with minimal, correct changes.

## Required process
1. Reproduce failures first.
2. Group failures by root cause.
3. Apply smallest coherent patch.
4. Re-run the same test set and report deltas.

## Constraints
- Do not change external behavior unless required by tests/spec.
- Do not weaken assertions just to get green.
- Do not bypass tests.

## Acceptance criteria
- Previously failing tests now pass.
- No unrelated refactor churn.
- Patch includes rationale per root cause.

## Completion report format
- Failing tests before
- Root causes
- Fixes applied
- Test results after
