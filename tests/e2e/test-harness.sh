#!/bin/bash
# =============================================================================
# Myco E2E Test Harness
# =============================================================================
# A framework for running end-to-end tests against the myco binary.
# This framework is designed to work when CLI/Phase 3 is implemented.
#
# Usage:
#   ./test-harness.sh <test-script>
#   ./test-harness.sh --help
#
# Environment variables:
#   MYCO_BINARY   - Path to myco binary (default: ./zig-out/bin/myco)
#   MYCO_DATA_DIR - Path to data directory (default: /tmp/myco-test-$$)
#   MYCO_VERBOSE  - Set to 1 for verbose output
# =============================================================================

set -euo pipefail

# Defaults
MYCO_BINARY="${MYCO_BINARY:-./zig-out/bin/myco}"
MYCO_DATA_DIR="${MYCO_DATA_DIR:-/tmp/myco-test-$$}"
MYCO_VERBOSE="${MYCO_VERBOSE:-0}"
MYCO_PORT="${MYCO_PORT:-9876}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
# Helper Functions
# =============================================================================

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
    if [[ "$MYCO_VERBOSE" == "1" ]]; then
        echo -e "[DEBUG] $*"
    fi
}

# Check if myco binary exists
check_binary() {
    if [[ ! -x "$MYCO_BINARY" ]]; then
        log_fail "Myco binary not found at: $MYCO_BINARY"
        log_info "Run 'zig build' first to build the binary"
        exit 1
    fi
    log_debug "Using myco binary: $MYCO_BINARY"
}

# Setup test environment
setup() {
    log_debug "Setting up test environment..."
    
    # Create data directory
    mkdir -p "$MYCO_DATA_DIR"
    
    # Clean up any existing data
    rm -rf "$MYCO_DATA_DIR"/*
    
    log_debug "Test data directory: $MYCO_DATA_DIR"
}

# Teardown test environment
teardown() {
    log_debug "Tearing down test environment..."
    
    # Kill any running myco processes
    pkill -f "myco.*$MYCO_DATA_DIR" 2>/dev/null || true
    
    # Clean up data directory (optional, keep for debugging)
    # rm -rf "$MYCO_DATA_DIR"
}

# Start myco in background
start_myco() {
    local args="${1:-}"
    
    log_debug "Starting myco with args: $args"
    
    # Start in background
    $MYCO_BINARY $args &
    MYCO_PID=$!
    
    # Wait for startup
    sleep 1
    
    # Check if still running
    if ! kill -0 "$MYCO_PID" 2>/dev/null; then
        log_fail "Failed to start myco"
        return 1
    fi
    
    log_debug "myco started with PID: $MYCO_PID"
    echo "$MYCO_PID"
}

# Stop myco
stop_myco() {
    local pid="${1:-$MYCO_PID}"
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log_debug "Stopping myco (PID: $pid)"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# Run a single test
run_test() {
    local test_name="$1"
    local test_func="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    log_debug "Running test: $test_name"
    
    if eval "$test_func"; then
        log_pass "$test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_fail "$test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Print test summary
print_summary() {
    echo ""
    echo "========================================"
    echo "Test Summary"
    echo "========================================"
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "========================================"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Show usage
usage() {
    cat << EOF
Myco E2E Test Harness

Usage: $(basename "$0") <test-script> [options]

Options:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -b, --binary PATH   Path to myco binary
    -d, --data-dir DIR  Path to data directory

Examples:
    $(basename "$0") test-cli.sh
    $(basename "$0") test-cli.sh --verbose
    MYCO_BINARY=/custom/path/test/myco $(basename "$0") test-cli.sh

Environment Variables:
    MYCO_BINARY   - Path to myco binary (default: ./zig-out/bin/myco)
    MYCO_DATA_DIR - Path to data directory (default: /tmp/myco-test-$$)
    MYCO_VERBOSE  - Set to 1 for verbose output
EOF
}

# =============================================================================
# Main
# =============================================================================

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--verbose)
            MYCO_VERBOSE=1
            shift
            ;;
        -b|--binary)
            MYCO_BINARY="$2"
            shift 2
            ;;
        -d|--data-dir)
            MYCO_DATA_DIR="$2"
            shift 2
            ;;
        -*)
            log_fail "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            TEST_SCRIPT="$1"
            shift
            ;;
    esac
done

# Check required arguments
if [[ -z "${TEST_SCRIPT:-}" ]]; then
    log_fail "No test script specified"
    usage
    exit 1
fi

# Check binary
check_binary

# Setup
setup

# Source test script (provides test functions)
if [[ -f "$TEST_SCRIPT" ]]; then
    source "$TEST_SCRIPT"
else
    log_fail "Test script not found: $TEST_SCRIPT"
    exit 1
fi

# Run tests
if declare -f | grep -q "^test_"; then
    for test_func in $(declare -f | grep "^test_" | cut -d' ' -f3); do
        run_test "$test_func" "$test_func"
    done
else
    log_warn "No test functions found in $TEST_SCRIPT"
fi

# Teardown
teardown

# Print summary
print_summary
exit $?
