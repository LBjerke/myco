# Dagger Agent Pipeline Plan (Build → Fix → Review Loop → Security → PR)

This plan describes an orchestrated agent pipeline in Dagger for feature delivery.

## Pipeline stages

1. **Stage A: Builder/Test Generator Agent**
   - Input: feature request + contracts.
   - Output:
     - candidate tests (unit/integration/simulation as appropriate)
     - acceptance checklist artifact (`artifacts/acceptance.json`)
   - Gate: tests compile and execute (pass/fail allowed at this stage).

2. **Stage B: Implement/Fix Agent**
   - Input: failing tests + feature request + constraints.
   - Output:
     - code changes to make tests pass
     - patch summary artifact (`artifacts/fix-summary.md`)
   - Gate: target test suite passes.

3. **Stage C: Reviewer Agent**
   - Input: diff + acceptance checklist + test results.
   - Output:
     - review verdict artifact (`artifacts/review.json`) with:
       - decision: APPROVE or REJECT_WITH_ACTIONS
       - required actions (if reject)
   - Gate:
     - If REJECT_WITH_ACTIONS: loop back to Stage B
     - If APPROVE: continue

4. **Stage D: Security Agent**
   - Input: approved diff.
   - Output:
     - security report (`artifacts/security.json`) with severities
   - Gate:
     - Block on Critical/High findings
     - Allow Medium/Low with documented follow-up ticket policy

5. **Stage E: PR Creator**
   - Input: approved+secure branch
   - Output:
     - push branch
     - open PR with summary, test evidence, review/security artifacts

---

## Control-loop design

Use a bounded loop around stages B and C.

- `MAX_REVIEW_LOOPS=3` (configurable)
- Pseudocode:

```text
run Stage A
run Stage B
for i in 1..MAX_REVIEW_LOOPS:
  run Stage C
  if verdict == APPROVE: break
  run Stage B with remediation list
if verdict != APPROVE: fail pipeline
run Stage D
if security_blocked: fail pipeline
run Stage E
```

---

## Dagger implementation blueprint

Create a dedicated orchestrator entrypoint, e.g. `ci/agentic/main.go`.

### Core containers
- `base`: tooling (zig/go/python/jq/git/gh)
- `agent-runner`: executes prompts against selected coding agent CLI
- `tester`: runs deterministic test targets (`test-fast`, selected suites)
- `security`: static/dependency/security checks

### Required environment/config
- `AGENT_CMD` (how to invoke coding agent)
- `GITHUB_TOKEN` (for PR stage)
- `GITHUB_REPO` (owner/repo)
- `BASE_BRANCH` (default: main)
- `FEATURE_BRANCH`
- `MAX_REVIEW_LOOPS` (default: 3)

### Artifacts contract
- `artifacts/acceptance.json`
- `artifacts/test-results.json`
- `artifacts/review.json`
- `artifacts/security.json`
- `artifacts/pr-body.md`

Each stage reads prior artifacts and writes a new one. Avoid hidden state.

---

## Suggested acceptance schema

`acceptance.json` example:

```json
{
  "feature": "<name>",
  "requirements": [
    {"id": "R1", "text": "...", "testRefs": ["tests/...::case"]}
  ],
  "mustPassSuites": ["test-fast"],
  "forbiddenChanges": ["wire-format-without-flag"]
}
```

`review.json` example:

```json
{
  "decision": "REJECT_WITH_ACTIONS",
  "actions": [
    "Add edge-case test for lease expiry",
    "Fix overflow handling in Placement table"
  ],
  "confidence": "medium"
}
```

---

## Security stage recommendations

Run at least:
- secrets scan on diff
- dependency audit
- static checks relevant to language/runtime
- policy checks for insecure defaults (permissions/plaintext flags)

Block conditions:
- any Critical/High finding unresolved
- any explicit policy violation in acceptance rules

---

## PR stage behavior

On success:
1. Commit with structured message:
   - `feat(<area>): <feature>`
2. Push feature branch
3. Create PR using `gh pr create` including:
   - feature summary
   - acceptance checklist mapping
   - test evidence
   - reviewer verdict
   - security report summary

If PR already exists, update body/comment with latest artifact summary.

---

## Rollout plan (incremental)

1. **Phase 1:** Implement Stage B only (fix tests from deterministic prompt).
2. **Phase 2:** Add Stage C reviewer + bounded loop.
3. **Phase 3:** Add Stage D security blocking.
4. **Phase 4:** Add Stage E automated PR creation.
5. **Phase 5:** Add metrics dashboard (loop count, pass rate, mean repair cycles).

This prevents overbuilding before the basic loop is stable.
