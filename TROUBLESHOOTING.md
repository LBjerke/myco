# Troubleshooting Guide

This guide covers common issues you might encounter when building and running Myco.

## Table of Contents
- [Build Issues](#build-issues)
- [Runtime Issues](#runtime-issues)
- [Networking & Peers](#networking--peers)
- [Data & State](#data--state)
- [Getting More Help](#getting-more-help)

---

## Build Issues

### "Zig not found" or "unknown Zig version"

**Problem**: The build fails because Zig isn't installed or is the wrong version.

**Solution**:
```bash
# Check your Zig version
zig version

# Install Zig 0.15.x (recommended)
# Option 1: Download from ziglang.org
# Option 2: Use zigup
curl -sL https://raw.githubusercontent.com/nickel-lang/zigup/master/zigup.sh | sh
zigup 0.15.0
```

### "permission denied" during build on macOS

**Problem**: Build fails with cache permission errors.

**Solution**:
```bash
# Set explicit cache directories
export ZIG_GLOBAL_CACHE_DIR=~/zig-cache
export ZIG_LOCAL_CACHE_DIR=~/zig-cache
zig build
```

### Build succeeds but binary is missing

**Problem**: `zig build` completes but `./zig-out/bin/myco` doesn't exist.

**Solution**: Check if the build produced an executable:
```bash
ls -la zig-out/bin/
```

If empty, check `build.zig` to confirm the install target is defined correctly.

---

## Runtime Issues

### "Address already in use"

**Problem**: Can't start daemon because port is already taken.

**Solution**:
```bash
# Find what's using the port (default 7777)
lsof -i :7777
# or
ss -tlnp | grep 7777

# Use a different port
MYCO_PORT=7778 ./zig-out/bin/myco daemon
```

### "Permission denied" when accessing data directory

**Problem**: Can't create or read files in the state directory.

**Solution**:
```bash
# Check directory permissions
ls -la /var/lib/myco

# Create the directory with proper permissions
sudo mkdir -p /var/lib/myco
sudo chown $USER /var/lib/myco

# Or use a directory you own
MYCO_STATE_DIR=/tmp/myco ./zig-out/bin/myco daemon
```

### Daemon starts but exits immediately

**Problem**: The daemon process terminates right after starting.

**Solution**:
```bash
# Run with verbose output to see what's happening
MYCO_LOG_LEVEL=debug ./zig-out/bin/myco daemon

# Check for missing required directories
mkdir -p /var/lib/myco
```

### "Connection refused" when connecting to API

**Problem**: Can't connect to the Myco API socket.

**Solution**:
```bash
# Check if the socket exists
ls -la /tmp/myco.sock  # or your configured UDS path

# Verify the daemon is running
ps aux | grep myco

# Check the configured socket path
MYCO_UDS_PATH=/tmp/myco.sock ./zig-out/bin/myco daemon
```

---

## Networking & Peers

### Nodes can't discover each other

**Problem**: Peer add command works but nodes don't exchange data.

**Checklist**:
1. **Firewall**: Are ports open?
   ```bash
   # Check if port is listening
   ss -tlnp | grep 7777
   
   # Test connectivity
   telnet <peer-ip> 7777
   ```

2. **Public keys**: Are you using the correct hex public key?
   ```bash
   # Get your public key
   ./zig-out/bin/myco pubkey
   ```

3. **Network interfaces**: Is the IP reachable?
   ```bash
   # Try binding to a specific interface
   MYCO_BIND_ADDR=192.168.1.100 ./zig-out/bin/myco daemon
   ```

### Gossip packets not being sent/received

**Problem**: peers are connected but state isn't syncing.

**Solution**:
```bash
# Enable debug logging
MYCO_LOG_LEVEL=debug ./zig-out/bin/myco daemon

# Check for packet encoding issues
# Look for "encode" or "gossip" in logs
```

### "Handshake failed" or "invalid peer"

**Problem**: Can't add a peer due to handshake errors.

**Solution**:
1. Make sure both nodes are running the same version of Myco
2. Check that you're using the correct public key (no copy-paste errors)
3. Verify both nodes have valid identities:
   ```bash
   ./zig-out/bin/myco pubkey
   ```

---

## Data & State

### WAL won't replay on restart

**Problem**: After restarting, the node has lost its state.

**Checklist**:
1. Is the WAL file intact?
   ```bash
   ls -la /var/lib/myco/wal/
   ```

2. Is the WAL directory writable?
   ```bash
   # Test write access
   touch /var/lib/myco/wal/test
   rm /var/lib/myco/wal/test
   ```

3. Check for WAL corruption (errors in logs about CRC/checksum)

### Reset all state and start fresh

**Problem**: You want a clean slate.

**Solution**:
```bash
# Stop the daemon first
pkill myco

# Remove state directory (careful!)
rm -rf /var/lib/myco
# or for dev mode
rm -rf /tmp/myco-state

# Recreate directory
mkdir -p /var/lib/myco

# Restart
./zig-out/bin/myco daemon
```

### Node shows stale/old data

**Problem**: A node has outdated information about other nodes or services.

**Solution**:
1. Check the node's last_seen timestamp in logs
2. Force a gossip round by waiting (gossip runs periodically)
3. Restart the stale node to trigger full state sync

---

## Getting More Help

### Enable Debug Logging

Many issues become clearer with debug output:
```bash
# Set log level via environment
MYCO_LOG_LEVEL=debug ./zig-out/bin/myco daemon

# Available levels: error, warn, info, debug
```

### Check Systemd Logs (if running as a service)

```bash
# View logs
journalctl -u myco -f

# Last 100 lines
journalctl -u myco -n 100
```

### Useful Commands

```bash
# Get node info
./zig-out/bin/myco info

# List peers
./zig-out/bin/myco peer list

# Check version
./zig-out/bin/myco version
```

### Still Stuck?

1. Check [GitHub Issues](https://github.com/myco-project/myco/issues)
2. Search the [Proposal Docs](./proposal/) for architectural details
3. Review the [GLOSSARY](./GLOSSARY.md) for term definitions

---

## Common Error Messages

| Error Message | Likely Cause | Solution |
|--------------|--------------|----------|
| `Address already in use` | Port in use | Use different port or free the port |
| `Connection refused` | Daemon not running or socket misconfigured | Check daemon status and socket path |
| `Permission denied` | Missing file/directory permissions | Check directory ownership and permissions |
| `Invalid peer` | Wrong public key or version mismatch | Verify peer key and version |
| `WAL write failed` | Disk full or directory not writable | Check disk space and directory permissions |
| `CRC mismatch` | WAL corruption | May need to reset state |
