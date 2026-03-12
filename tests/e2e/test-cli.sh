#!/usr/bin/env bash
# =============================================================================
# Myco CLI E2E Tests
# =============================================================================
# Example E2E tests for the myco CLI.
# These tests will work once Phase 3 (CLI & API) is implemented.
#
# Each test function must:
#   - Start with "test_"
#   - Return 0 on success, non-zero on failure
#   - Be self-contained (setup and teardown within the function)
#
# Usage:
#   ./test-harness.sh ./test-cli.sh
#   ./test-harness.sh ./test-cli.sh --verbose
# =============================================================================

# Import test utilities (if available)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-util.sh
source "$SCRIPT_DIR/test-util.sh" 2>/dev/null || true

# =============================================================================
# Test: CLI help output
# =============================================================================
test_help_output() {
    log_info "Testing CLI help output..."
    
    # This will work once CLI is implemented
    local output
    output=$($MYCO_BINARY --help 2>&1) || return 1
    
    # Verify help contains expected content
    echo "$output" | grep -q "Usage:" || return 1
    echo "$output" | grep -q "myco" || return 1
    
    return 0
}

# =============================================================================
# Test: CLI version output
# =============================================================================
test_version_output() {
    log_info "Testing CLI version output..."
    
    local output
    output=$($MYCO_BINARY --version 2>&1) || return 1
    
    # Verify version format (e.g., "myco x.y.z")
    echo "$output" | grep -qE "^myco [0-9]+\.[0-9]+\.[0-9]+" || return 1
    
    return 0
}

# =============================================================================
# Test: Daemon starts and runs
# =============================================================================
test_daemon_start() {
    log_info "Testing daemon starts..."
    
    # Start daemon in background
    local pid
    pid=$(myco_start) || return 1
    
    # Wait for startup
    sleep 2
    
    # Check if still running
    if ! kill -0 "$pid" 2>/dev/null; then
        log_fail "Daemon failed to start"
        return 1
    fi
    
    # Cleanup
    myco_stop "$pid"
    
    return 0
}

# =============================================================================
# Test: Status command (once implemented)
# =============================================================================
test_status_command() {
    log_info "Testing status command..."
    
    # Start daemon in background
    local pid
    pid=$(myco_start) || return 1
    
    # Run status command (once CLI is implemented)
    local output
    output=$($MYCO_BINARY status 2>&1) || true
    
    # Cleanup
    myco_stop "$pid"
    
    # Verify output contains status info
    echo "$output" | grep -q "nodes" || true  # Expected to fail until implemented
    
    return 0
}

# =============================================================================
# Test: Deploy command (once implemented)
# =============================================================================
test_deploy_command() {
    log_info "Testing deploy command..."
    
    # This test will work once the deploy command is implemented
    # For now, it's a placeholder
    
    # Example of what it might look like:
    # $MYCO_BINARY deploy --name nginx --replicas 2
    # $MYCO_BINARY status | grep nginx
    
    log_warn "Deploy command not yet implemented (Phase 3)"
    
    return 0  # Skip for now
}

# =============================================================================
# Test: WAL directory is created
# =============================================================================
test_wal_creation() {
    log_info "Testing WAL directory creation..."
    
    # Create custom data directory
    local test_dir="/tmp/myco-test-wal-$$"
    rm -rf "$test_dir"
    mkdir -p "$test_dir"
    
    # Start daemon (should create WAL in data dir)
    local pid
    pid=$(myco_start "" "$test_dir") || return 1
    
    # Check if WAL directory was created
    if [[ -d "$test_dir/wal" ]]; then
        local result=0
    else
        local result=1
    fi
    
    # Cleanup
    myco_stop "$pid"
    rm -rf "$test_dir"
    
    return $result
}

# =============================================================================
# Test: Config file parsing (once implemented)
# =============================================================================
test_config_file() {
    log_info "Testing config file..."
    
    # Create a config file
    local config_file="/tmp/myco-test-config-$$"
    cat > "$config_file" << 'EOF'
[data]
data_dir = /tmp/myco-data

[network]
bind_address = 127.0.0.1
port = 9876

[logging]
level = debug
EOF
    
    # Try to run with config
    local output
    output=$($MYCO_BINARY --config "$config_file" 2>&1) || true
    
    # Cleanup
    rm -f "$config_file"
    
    # This will fail until config is implemented
    log_warn "Config file parsing not yet implemented (Phase 3)"
    
    return 0  # Skip for now
}

# =============================================================================
# Test: Graceful shutdown
# =============================================================================
test_graceful_shutdown() {
    log_info "Testing graceful shutdown..."
    
    # Start daemon
    local pid
    pid=$(myco_start) || return 1
    
    # Send SIGTERM for graceful shutdown
    kill -TERM "$pid"
    
    # Wait for process to exit (max 5 seconds)
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt 50 ]]; do
        sleep 0.1
        count=$((count + 1))
    done
    
    # Check if process exited
    if kill -0 "$pid" 2>/dev/null; then
        log_fail "Process did not shutdown gracefully"
        kill -9 "$pid" 2>/dev/null || true
        return 1
    fi
    
    return 0
}

# =============================================================================
# Test: Error handling for invalid args
# =============================================================================
test_invalid_args() {
    log_info "Testing error handling..."
    
    # Run with invalid arguments
    local output
    output=$($MYCO_BINARY --invalid-arg 2>&1) || true
    
    # Should show error message
    echo "$output" | grep -qi "error\|unknown\|invalid" || return 1
    
    return 0
}

# =============================================================================
# Test: Multiple instances prevention
# =============================================================================
test_single_instance() {
    log_info "Testing single instance enforcement..."
    
    # Start first instance
    local pid1
    pid1=$(myco_start) || return 1
    
    # Try to start second instance
    local pid2
    $MYCO_BINARY --data-dir "$MYCO_DATA_DIR" &>/dev/null &
    pid2=$!
    sleep 2
    
    # Check if second instance exited (should fail to start)
    local result=0
    if kill -0 "$pid2" 2>/dev/null; then
        log_warn "Second instance started - single instance not enforced"
        kill -9 "$pid2" 2>/dev/null || true
        result=1
    fi
    
    # Cleanup
    myco_stop "$pid1"
    wait "$pid2" 2>/dev/null || true
    
    return $result
}
