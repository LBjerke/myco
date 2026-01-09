# Gemini Added Memories

## Project Overview
The project, "Myco", is a decentralized orchestration system written primarily in Zig, with a Go component for CI/CD. It provides a CLI for initializing projects, managing a daemon that handles gossip and API requests, deploying services using Nix and Systemd, and peer management.

## Development Conventions
*   **Core**: Zig. **CI**: Go. **Orchestration**: Nix + Systemd.
*   **Testing**: Thorough simulation tests required (`make sim-*`).

## Agent Workflow & Verification
**Crucial:** Verify changes before completion.

1.  **Fast Feedback (Unit Tests):**
    ```bash
    zig build test-sim && zig build test-engine && zig build test-cli && zig build test-crdt && zig build test-units
    ```
2.  **Code Complexity:**
    ```bash
    lizard --languages zig --max-complexity 9 src/
    ```
3.  **Full Verification (CI Pipeline):**
    ```bash
    go run ./ci/main.go
    ```
    **ALWAYS** run this. It handles formatting, building, and all tests.

4.  **Simulation Tests (Complex Logic):**
    If modifying gossip, run: `make sim-50-realworld`

## CLI Usage
*   **Init:** `myco init`
*   **Daemon:** `myco daemon`
*   **Deploy:** `myco deploy`
*   **Status:** `myco status`
*   **Add Peer:** `myco peer add <PUBKEY_HEX> <IP:PORT>`