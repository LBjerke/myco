# Myco: The Sovereign Cloud Orchestrator

Myco is a single-binary tool that turns any Linux machine (especially Raspberry Pis) into a sovereign cloud node.

## Features
- **Zero Dependencies:** No Docker daemon, no Kubernetes, just a static binary.
- **Nix-Powered:** Atomic, reproducible builds for every service.
- **Systemd-Native:** Uses the Linux kernel's native process isolation.
- **Secrets Management:** Securely injects credentials from the host.

## Quick Start

1. **Install** (Requires Nix installed)
   ```bash
   # Download the binary (Coming soon) or build from source
   zig build -Doptimize=ReleaseSmall
   sudo cp zig-out/bin/myco /usr/local/bin/
   ```

2. **Initialize a Service**
   ```bash
   # Create a config interactively
   sudo myco init
   ```

3. **Run the Cluster**
   ```bash
   # Build and start all services
   sudo -E myco up
   ```

4. **Debug**
   ```bash
   # Stream logs
   sudo myco logs <service_name>
   ```

## Configuration Example (`services/minio.json`)
```json
{
    "name": "minio",
    "package": "nixpkgs#minio",
    "port": 9000,
    "env": [
        "MINIO_ROOT_USER=admin",
        "MINIO_ROOT_PASSWORD=$HOST_ENV_VAR"
    ]
}
```

