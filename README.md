# Myco: Sovereign Cloud Orchestrator

Myco is a single-binary (<500KB) tool that turns Raspberry Pis into a self-healing, encrypted mesh cloud.

## Quick Start

1.  **Install**
    ```bash
    curl -L myco.dev/install | bash
    # Or build from source: zig build -Doptimize=ReleaseSmall
    ```

2.  **Initialize Node**
    ```bash
    sudo myco init
    sudo -E myco up
    ```

3.  **Connect Nodes (The Mesh)**
    ```bash
    # On Node A
    sudo myco id
    # On Node B
    sudo myco peer add node-a <IP_OF_NODE_A>
    sudo myco deploy caddy node-a
    ```

4.  **Manage Data**
    ```bash
    # Backup
    sudo myco snapshot minio
    
    # Teleport Data to another node
    sudo myco send-snapshot /var/lib/myco/backups/minio-123.tar.gz <TARGET_IP>
    
    # Restore
    sudo myco restore minio /var/lib/myco/backups/minio-123.tar.gz
    ```

5.  **Monitor**
    ```bash
    sudo myco monitor
    ```
