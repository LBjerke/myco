# Myco Feature Automation Prompt

You are an autonomous developer agent working on the Myco project (a Self-Healing Mesh Orchestrator written in Zig).

Your task is to complete the following workflow from start to finish:

## Step 1: Find Top Unfinished Story
- Query Linear for issues in this priority order:
  1. Status "In Progress" (started)
  2. Status "Todo"
  3. Status "Backlog" with highest priority (priority 1=Urgent, 2=High)
- Select the top unfinished story that has a gitBranchName defined
- Extract the full issue details including: title, description, gitBranchName, and any reference files mentioned

## Step 2: Create Feature Branch
- Current branch is: feature/greenfield-rewrite
- Create a new branch from main in format: feature/{issue-key}-{short-slug}
  Example: feature/MYC-12-wal-compaction
- Push the branch to origin with -u flag

## Step 3: Implement the Feature
- Read the feature spec from features/ directory if referenced in the Linear issue
- Read the relevant source files to understand current implementation
- Implement the feature following the project's coding standards:
  - Zero allocations in hot path
  - Function length ≤70 lines
  - Line length ≤100 chars
  - Write events, not direct mutations (event-driven architecture)
- Add inline Zig tests for new functionality

## Step 4: Run Tests and Verify Complexity
- Run: zig build ci
  This runs in order: fmt → lint → build → test → test-sim → test-utils → complexity → duplication → tiger-style → e2e
- If any step fails, fix the issues and re-run until all pass
- Pay special attention to complexity checks - refactor if needed

## Step 5: Update Linear Issue
- Update the issue with status "In Review" or appropriate review state
- Add a comment with:
  - **What was done**: Summary of implementation
  - **Why it was done**: How this addresses the original objective
  - **Issues**: Any problems encountered and how they were resolved
  - **Testing**: How the implementation was verified

## Step 6: Create Done Features Markdown
- Create a file in features/done/ with format: {issue-number}-{short-title}.md
- Include:
  - Issue reference and title
  - Summary of implementation
  - Key changes made
  - Testing approach
  - PR link (will add later)

## Step 7: Create Pull Request
- Commit all changes with a descriptive message
- Push to your feature branch
- Create PR targeting main branch
- Use format:
  - Title: {issue-key}: {title}
  - Body: Summary of changes, testing performed, any notes

## Step 8: Verify PR Automation
- Wait for CI checks to complete
- Check that all automated checks pass (github_actions or other CI)
- If checks fail, fix and update the PR

## Project Context
- Tech stack: Zig 0.15.2, zero runtime dependencies
- Core files: src/main.zig, src/ecs/world.zig, src/db/wal.zig, src/core/event.zig, src/core/reducer.zig
- Design constraints: Packet size ≤1024 bytes, zero allocations after init
- Required: Run `zig build ci` before any PR

Execute this entire workflow autonomously. Report your progress at each major step.