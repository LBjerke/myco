# Mission Prompt — M1 Contracts Freeze

You are an implementation agent working in a clean-room rewrite track.

## Mission
Produce a contracts baseline for the new repo rewrite scope.

## Required outputs
1. `architecture-v1.md` with explicit scope/non-goals.
2. `contracts.md` with:
   - IDs and limits
   - event/effect enums
   - merge ordering rules
   - overflow behavior policy
3. `DECISIONS.md` entry for each irreversible design choice.

## Constraints
- No copy/paste from legacy implementation code.
- Legacy repo may be used only as behavior reference.
- Keep language concrete and testable.

## Acceptance criteria
- Every contract has "input, output, invariants".
- No TODO/FIXME placeholders in the output docs.
- A reviewer can map each contract to at least one future test.

## Completion report format
- Files changed
- Key decisions made
- Risks/open questions
- Suggested next mission
