#!/bin/bash
# =============================================================================
# E2E Test Utilities
# =============================================================================
# Common utility functions for E2E tests.
# Source this file in your test scripts.
#
# Usage:
#   source "$(dirname "$0")/test-util.sh"
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# Logging
# =============================================================================

log() {
    echo -e "${CYAN}[TEST]${NC} $*"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_debug() {
    if [[ "${TEST_DEBUG:-0}" == "1" ]]; then
        echo -e "[DEBUG] $*"
    fi
}

# =============================================================================
# Assertions
# =============================================================================

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" != "$actual" ]]; then
        log_fail "Assertion failed: expected '$expected', got '$actual'"
        [[ -n "$msg" ]] && log_fail "$msg"
        return 1
    fi
    return 0
}

assert_ne() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        log_fail "Assertion failed: expected '$expected' != '$actual'"
        [[ -n "$msg" ]] && log_fail "$msg"
        return 1
    fi
    return 0
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File does not exist}"

    if [[ ! -f "$file" ]]; then
        log_fail "$msg: $file"
        return 1
    fi
    return 0
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory does not exist}"

    if [[ ! -d "$dir" ]]; then
        log_fail "$msg: $dir"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-String does not contain substring}"

    if [[ "$haystack" != *"$needle"* ]]; then
        log_fail "$msg"
        log_fail "  Looking for: '$needle'"
        log_fail "  In: '$haystack'"
        return 1
    fi
    return 0
}

assert_cmd_exists() {
    local cmd="$1"

    if ! command -v "$cmd" &> /dev/null; then
        log_fail "Command not found: $cmd"
        return 1
    fi
    return 0
}

# =============================================================================
# Process Management
# =============================================================================

# Start myco in background
myco_start() {
    local args="${1:-}"
    local data_dir="${2:-$MYCO_DATA_DIR}"
    
    log_debug "Starting myco with args: $args"
    
    $MYCO_BINARY --data-dir "$data_dir" $args &>/dev/null &
    local pid=$!
    
    # Wait a bit for startup
    sleep 1
    
    # Verify it's running
    if ! kill -0 "$pid" 2>/dev/null; then
        log_fail "Failed to start myco"
        return 1
    fi
    
    echo "$pid"
}

# Stop myco by PID
myco_stop() {
    local pid="$1"
    local timeout="${2:-5}"
    
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log_debug "Process $pid not running"
        return 0
    fi
    
    log_debug "Stopping myco (PID: $pid)"
    
    # Try graceful shutdown first
    kill -TERM "$pid" 2>/dev/null || true
    
    # Wait for graceful shutdown
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $((timeout * 10)) ]]; do
        sleep 0.1
        count=$((count + 1))
    done
    
    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        log_debug "Force killing myco"
        kill -9 "$pid" 2>/dev/null || true
    fi
    
    wait "$pid" 2>/dev/null || true
    
    log_debug "myco stopped"
}

# Wait for myco to be ready
myco_wait_ready() {
    local timeout="${1:-10}"
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        # Try to connect or check status
        if $MYCO_BINARY status &>/dev/null; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    return 1
}

# =============================================================================
# File Operations
# =============================================================================

# Create temp directory for tests
temp_dir() {
    mktemp -d "myco-test-XXXXXX"
}

# Clean up temp files on exit
cleanup_on_exit() {
    local temp_dirs=("$@")
    for dir in "${temp_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
        fi
    done
}

# =============================================================================
# Network Operations
# =============================================================================

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local timeout="${2:-10}"
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if ! netstat -tuln 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    
    return 1
}

# Check if port is in use
port_in_use() {
    local port="$1"
    netstat -tuln 2>/dev/null | grep -q ":$port " && return 0 || return 1
}

# =============================================================================
# JSON Operations (requires jq)
# =============================================================================

# Parse JSON value
json_get() {
    local json="$1"
    local key="$2"
    
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key // empty"
    else
        log_warn "jq not installed, cannot parse JSON"
        echo ""
        return 1
    fi
}

# =============================================================================
# Skip Test
# =============================================================================

skip_test() {
    local reason="${1:-No reason provided}"
    log_warn "SKIPPED: $reason"
    exit 0
}

# =============================================================================
# Test Setup/Teardown Hooks
# =============================================================================

# Called before each test
test_setup() {
    log_debug "Test setup..."
    # Override in your test script
}

# Called after each test
test_teardown() {
    log_debug "Test teardown..."
    # Override in your test script
    
    # Kill any lingering myco processes from this test
    pkill -f "myco.*test" 2>/dev/null || true
}
