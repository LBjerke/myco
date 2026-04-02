# Troubleshooting Guide

This guide covers common issues you might encounter when building and running Myco.

## Table of Contents
- [Build Issues](#build-issues)
- [Runtime Issues](#runtime-issues)
- [Getting More Help](#getting-more-help)

---

## Build Issues

### "Zig not found" or "unknown Zig version"

**Problem**: The build fails because Zig isn't installed or is the wrong version.

**Solution**:
```bash
# Check your Zig version
zig version

# Install Zig 0.15.2
# Option 1: Download from ziglang.org
# Option 2: Use zigup
curl -sL https://raw.githubusercontent.com/nickel-lang/zigup/master/zigup.sh | sh
zigup 0.15.2
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

---

## Runtime Issues

### Daemon starts but exits immediately

**Problem**: The daemon process terminates right after starting.

**Solution**:
```bash
# Run with verbose output
./zig-out/bin/myco

# Check for missing required directories
mkdir -p data/wal
```

### WAL won't replay on restart

**Problem**: After restarting, the node has lost its state.

**Checklist**:
1. Is the WAL directory intact?
   ```bash
   ls -la data/wal/
   ```
2. Is the WAL directory writable?
   ```bash
   touch data/wal/test
   rm data/wal/test
   ```
3. Check for WAL corruption in output

### Reset all state and start fresh

**Problem**: You want a clean slate.

**Solution**:
```bash
# Stop the daemon first
pkill myco || true

# Remove state directories (careful!)
rm -rf data/wal

# Recreate directory
mkdir -p data/wal

# Restart
./zig-out/bin/myco
```

---

## Getting More Help

### Enable Debug Output

Run the binary directly to see all output:
```bash
./zig-out/bin/myco
```

### Check Build Errors

```bash
# Full build with all checks
zig build ci
```

### Useful Commands

```bash
# Check version
git describe --tags --always

# Check git status
git status

# List recent commits
git log --oneline -10
```

### Still Stuck?

1. Check [GitHub Issues](https://github.com/myco-project/myco/issues)
2. Search the [Proposal Docs](./docs/archive/proposal/) for architectural details
3. Review the [GLOSSARY](./GLOSSARY.md) for term definitions
4. Check [docs/architecture.md](./docs/architecture.md) for Phase 2 (planned) features

---

## Common Error Messages

| Error Message | Likely Cause | Solution |
|--------------|--------------|----------|
| Build fails | Missing Zig or wrong version | Install Zig 0.15.2 |
| Binary missing | Build didn't complete | Run `zig build` |
| WAL error | Directory not writable | Check `data/wal/` permissions |
| Exit immediately | Check output for errors | Run `./zig-out/bin/myco` directly |
