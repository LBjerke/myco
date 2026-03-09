# Milestones & Issues Board Template (Scratch Rewrite)

This document defines a practical GitHub Milestones + Issues structure for a clean-room rewrite (new repo), using the legacy repo only as behavioral reference.

---

## Project Setup

### Recommended labels
- `type:epic`
- `type:feature`
- `type:task`
- `type:bug`
- `type:test`
- `type:doc`
- `priority:P0`
- `priority:P1`
- `priority:P2`
- `area:core`
- `area:crdt`
- `area:wal`
- `area:gossip`
- `area:placement`
- `area:runtime`
- `area:cli-api`
- `area:ci`
- `risk:breaking`
- `risk:perf`
- `risk:security`
- `blocked`

### Recommended board columns
1. Backlog
2. Ready
3. In Progress
4. In Review
5. Validation
6. Done

### Recommended issue fields
- Milestone
- Priority
- Estimate (S/M/L)
- Risk
- Dependencies
- Acceptance Criteria

---

## Milestones (10-week baseline)

### M1 — Architecture & Contracts Freeze
**Outcome:** Contracts are explicit and stable enough to begin core implementation.

**Issues**
- [ ] Draft `architecture-v1.md` with final scope and non-goals
- [ ] Define core IDs, limits, event types, effect types
- [ ] Define CRDT merge rules and tie-break ordering
- [ ] Define overflow policy for all fixed-capacity tables
- [ ] Add repo skeleton and CI smoke check

**Exit criteria**
- No TODOs in contracts docs
- Placeholder modules compile and tests run

---

### M2 — Core State Model (No Side Effects)
**Outcome:** Fixed-capacity ECS-style tables + deterministic storage behavior.

**Issues**
- [ ] Implement NodeMeta table
- [ ] Implement JobSpecSummary table
- [ ] Implement Placement table
- [ ] Implement dirty-set tracking per table
- [ ] Add full-table/overflow unit tests

**Exit criteria**
- Deterministic iteration and updates proven by tests
- No heap allocation in hot paths

---

### M3 — CRDT + Reducer Engine
**Outcome:** Deterministic convergence logic in core.

**Issues**
- [ ] Implement HLC (`next`, `observe`, compare)
- [ ] Implement LWW merge for replicated components
- [ ] Implement placement merge (epoch > HLC > score > node_id)
- [ ] Implement core entrypoints (`applyProposal`, `mergeDelta`, `tick`)
- [ ] Add property tests for convergence semantics

**Exit criteria**
- Replay/order variation yields same final state
- Merge rules documented and tested

---

### M4 — WAL Adapter v2
**Outcome:** Durable event log with replay and integrity checks.

**Issues**
- [ ] Define WAL v2 header and entry kinds
- [ ] Implement append + fsync + CRC
- [ ] Implement replay iterator and corruption behavior
- [ ] Add compaction/snapshot design stub
- [ ] Add round-trip tests for all durable event kinds

**Exit criteria**
- Durable-before-side-effects rule implemented in integration path
- Replay reconstructs state in deterministic tests

---

### M5 — Gossip Codec v2
**Outcome:** Bounded, sectioned delta exchange format.

**Issues**
- [ ] Define packet section format and versioning
- [ ] Implement encode/decode for each replicated section
- [ ] Add stable-order packing and varint encoding
- [ ] Add malformed packet hardening tests
- [ ] Add size-budget tests (never exceed payload cap)

**Exit criteria**
- Encode/decode round-trips pass
- Size ceilings enforced in CI

---

### M6 — Placement Engine (Replicas + Hysteresis + Leases)
**Outcome:** Safe, deterministic scheduler behavior.

**Issues**
- [ ] Implement eligibility filters
- [ ] Implement deterministic scoring and tie-break
- [ ] Implement anti-affinity preference
- [ ] Implement lease renewal/steal rules
- [ ] Implement hysteresis thresholding to reduce churn

**Exit criteria**
- Oscillation bounded in simulation scenarios
- Expired lease takeover validated

---

### M7 — Runtime/Reconcile Adapter
**Outcome:** Idempotent desired-vs-actual execution.

**Issues**
- [ ] Implement reconcile planner
- [ ] Implement start/stop/restart execution adapter
- [ ] Add backoff and health checks
- [ ] Enforce “must own valid lease to run” guard
- [ ] Add crash/restart recovery integration tests

**Exit criteria**
- Reconcile is idempotent
- No execution without valid ownership

---

### M8 — Daemon + Thin CLI/API
**Outcome:** End-to-end minimal operational system.

**Issues**
- [ ] Wire loop phases (ingest → WAL → core → effects)
- [ ] Add minimal commands (status, deploy, peers)
- [ ] Add structured logs and key metrics
- [ ] Add local multi-node smoke workflow
- [ ] Add docs for quickstart + troubleshooting

**Exit criteria**
- Multi-node local convergence passes
- Basic operator workflow complete

---

### M9 — Hardening
**Outcome:** Security, performance, and failure-mode confidence.

**Issues**
- [ ] Security defaults review (socket perms, plaintext controls)
- [ ] Performance profiling and memory caps report
- [ ] WAL compaction/snapshot implementation
- [ ] Failure-injection tests (loss, partitions, disk pressure)
- [ ] Documentation polish for operators/contributors

**Exit criteria**
- P0 issues closed
- Stability and resource budgets documented

---

### M10 — Pilot Readiness
**Outcome:** Clear go/no-go criteria for first real adoption.

**Issues**
- [ ] Define pilot targets (convergence, recovery, churn)
- [ ] Run pilot matrix and record outcomes
- [ ] Produce cutover/migration guide
- [ ] Create rollback and incident playbook
- [ ] Final release checklist

**Exit criteria**
- Pilot criteria met
- Rollback plan tested

---

## Issue Templates

### Epic Template
**Title:** `EPIC: <outcome>`

**Body:**
- Problem statement
- Desired outcome
- In scope / out of scope
- Dependencies
- Risks
- Milestone
- Definition of done

### Feature Template
**Title:** `feat(<area>): <capability>`

**Body:**
- User/system story
- Proposed design
- Edge cases
- Test plan
- Acceptance criteria
- Dependency links

### Task Template
**Title:** `task(<area>): <specific implementation step>`

**Body:**
- What to change
- Where (files/modules)
- Why now
- Validation steps
- Acceptance criteria

### Bug Template
**Title:** `bug(<area>): <symptom>`

**Body:**
- Observed behavior
- Expected behavior
- Repro steps
- Impact
- Suspected root cause
- Fix plan
- Regression tests required

---

## Example Initial Board (starter backlog)

- EPIC: Core deterministic state engine
- EPIC: Durable WAL v2 and replay safety
- EPIC: Gossip v2 bounded delta protocol
- EPIC: Replica placement with lease safety
- EPIC: Runtime reconcile and execution guards
- EPIC: End-to-end daemon + minimal CLI/API

---

## Governance Rules

1. No issue can enter **In Progress** without acceptance criteria.
2. No issue can move to **Done** without tests or explicit test waiver.
3. Any change to merge rules or wire format requires `risk:breaking` label.
4. Security-sensitive changes require explicit reviewer sign-off.
5. Track irreversible design choices in `DECISIONS.md`.
