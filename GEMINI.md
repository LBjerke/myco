# Gemini Added Memories

## Project Overview
Myco is a decentralized orchestration system (Zig + Go for CI). It provides a CLI for project init, daemon management (gossip, API), service deployment (Nix, Systemd), and peer management.

## Development Conventions
*   **Core Logic**: Zig.
*   **CI/Automation**: Go.
*   **Deployment**: Nix & Systemd.
*   **Testing**: Thorough (simulation, unit, integration).

## Agent Workflow & Verification
**Always verify changes thoroughly.**

1.  **Fast Feedback (Unit Tests):**
    ```bash
    zig build test-sim && zig build test-engine && zig build test-cli && zig build test-crdt && zig build test-units
    ```
2.  **Code Quality (Lizard):**
    ```bash
    lizard --languages zig --max-complexity 9 src/
    ```
3.  **Full CI Verification:**
    ```bash
    go run ./ci/main.go
    ```
    (Runs formatting, builds, all tests. **Crucial final step.**)

4.  **Simulation Tests (Specific):**
    `make sim-50-realworld` (for gossip/orchestration changes).
5. **Document what was done and why in the log/ folder:**

## Zero-Allocation Runtime
The Myco daemon aims for zero heap allocations after startup. This is enforced by `FrozenAllocator` and `noalloc_guard`. If refactoring, avoid new heap allocations in runtime loops.

## CLI Usage (Zig Executable)
*   `myco init`: Initialize Myco project.
*   `myco daemon`: Start the Myco node/daemon.
*   `myco deploy`: Deploy current directory as a service.
*   `myco status`: Query daemon metrics.
*   `myco peer add <PUBKEY_HEX> <IP:PORT>`: Add a neighbor peer.

## Agent Work Log
Refer to `log/AI_AGENT_LOG.md` for a chronological record of tasks performed by the AI agent on this repository.
