# Gemini Added Memories

## Project Overview

The project, "Myco", is a decentralized orchestration system written primarily in Zig, with a Go component for CI/CD. It provides a CLI for initializing projects, managing a daemon that handles gossip and API requests, deploying services using Nix and Systemd, and peer management.

## Building and Running

### Zig Project

The `build.zig` file defines the build process and various tests (simulation, engine, CLI, CRDT sync, unit tests).

*   **Build the main executable:**
    ```bash
    zig build
    ```
*   **Run specific simulation tests (as defined in `Makefile`):**
    ```bash
    make sim-50-realworld
    make sim-50-realworld-debug
    make sim-20-pi-wifi
    ```

### Go Project

The Go project is located in the `ci/` directory and is used for Continuous Integration tasks.

*   **Build the Go component:**
    ```bash
    go build -v ./ci/main.go
    ```
*   **Run the Go component:**
    ```bash
    go run -v ./ci/main.go
    ```

### CLI Usage (for the Zig executable)

Once the Zig executable `myco` is built, you can use the following commands:

*   **Initialize a Myco project:**
    ```bash
    myco init
    ```
*   **Start the Myco daemon:**
    ```bash
    myco daemon
    ```
*   **Deploy the current directory as a service:**
    ```bash
    myco deploy
    ```
*   **Query daemon metrics:**
    ```bash
    myco status
    ```
*   **Add a neighbor peer:**
    ```bash
    myco peer add <PUBKEY_HEX> <IP:PORT>
    ```

## Development Conventions

*   The core logic of the project is implemented in **Zig**.
*   **Go** is utilized for Continuous Integration and potentially other automation tasks.
*   **Nix** and **Systemd** are integral for service deployment and orchestration within the Myco ecosystem.
*   The project emphasizes thorough testing, with extensive **simulation tests** defined in `build.zig` and accessible via `make` commands.
*   After every code change, ensure to run `zig build test` to verify Zig changes and `go run ./ci/main.go` for Go CI validation.
