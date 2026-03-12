# Makefile for Myco: Self-Healing Mesh Orchestrator

# Project information
PROJECT = myco
VERSION = $(shell git describe --tags --always 2>/dev/null || echo "dev")

# Build configuration
ZIG = zig
BUILD_DIR = zig-out
BIN_DIR = $(BUILD_DIR)/bin
TARGET = $(shell $(ZIG) targets | grep "host" | head -1 | cut -d' ' -f2)

# Default target
.DEFAULT_GOAL := help

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m # No Color

# Help target - lists all available targets
.PHONY: help
help:
	@echo -e "$(BLUE)Myco: Self-Healing Mesh Orchestrator$(NC)"
	@echo -e "$(YELLOW)Version:$(NC) $(VERSION)"
	@echo -e "$(YELLOW)Target:$(NC) $(TARGET)"
	@echo ""
	@echo -e "$(GREEN)Available targets:$(NC)"
	@echo "  build           - Build the project"
	@echo "  build-release   - Build in release mode"
	@echo "  test            - Run all tests"
	@echo "  test-sim        - Run simulation tests"
	@echo "  test-utils      - Run test utility tests"
	@echo "  test-all        - Run all test suites"
	@echo "  test-e2e        - Run end-to-end tests"
	@echo "  test-e2e-verbose - Run E2E tests (verbose)"
	@echo "  test-e2e-binary - Run E2E tests with custom binary"
	@echo "  test-all-including-e2e - Run all tests including E2E"
	@echo "  clean           - Clean build artifacts"
	@echo "  install        - Install the binary"
	@echo "  uninstall      - Uninstall the binary"
	@echo "  run            - Run the application"
	@echo "  help           - Show this help message"

# Build targets
.PHONY: build
build:
	@echo -e "$(BLUE)Building $(PROJECT)...$(NC)"
	@$(ZIG) build

.PHONY: build-release
build-release:
	@echo -e "$(BLUE)Building $(PROJECT) in release mode...$(NC)"
	@$(ZIG) build -Doptimize=ReleaseFast

# Test targets
.PHONY: test
test:
	@echo -e "$(BLUE)Running all tests...$(NC)"
	@$(ZIG) build test

.PHONY: test-sim
test-sim:
	@echo -e "$(BLUE)Running simulation tests...$(NC)"
	@$(ZIG) build test-sim

.PHONY: test-utils
test-utils:
	@echo -e "$(BLUE)Running test utility tests...$(NC)"
	@$(ZIG) build test-utils

.PHONY: test-all
test-all: test test-sim test-utils
	@echo -e "$(GREEN)All tests passed!$(NC)"

# E2E test targets
.PHONY: test-e2e
test-e2e:
	@echo -e "$(BLUE)Running end-to-end tests...$(NC)"
	@cd tests/e2e && chmod +x test-harness.sh test-cli.sh && ./test-harness.sh ./test-cli.sh

.PHONY: test-e2e-verbose
test-e2e-verbose:
	@echo -e "$(BLUE)Running end-to-end tests (verbose)...$(NC)"
	@cd tests/e2e && chmod +x test-harness.sh test-cli.sh && MYCO_VERBOSE=1 ./test-harness.sh ./test-cli.sh --verbose

.PHONY: test-e2e-binary
test-e2e-binary:
	@echo -e "$(BLUE)Running end-to-end tests with custom binary...$(NC)"
	@cd tests/e2e && chmod +x test-harness.sh test-cli.sh && MYCO_BINARY=$(CURDIR)/zig-out/bin/myco ./test-harness.sh ./test-cli.sh

.PHONY: test-all-including-e2e
test-all-including-e2e: test-all test-e2e
	@echo -e "$(GREEN)All tests including E2E passed!$(NC)"

# Clean target
.PHONY: clean
clean:
	@echo -e "$(BLUE)Cleaning build artifacts...$(NC)"
	@rm -rf $(BUILD_DIR)
	@echo -e "$(GREEN)Clean complete!$(NC)"

# Install targets
.PHONY: install
install:
	@echo -e "$(BLUE)Installing $(PROJECT)...$(NC)"
	@mkdir -p $(DESTDIR)/usr/local/bin
	@cp $(BIN_DIR)/$(PROJECT) $(DESTDIR)/usr/local/bin/
	@echo -e "$(GREEN)Installation complete!$(NC)"

.PHONY: uninstall
uninstall:
	@echo -e "$(BLUE)Uninstalling $(PROJECT)...$(NC)"
	@rm -f $(DESTDIR)/usr/local/bin/$(PROJECT)
	@echo -e "$(GREEN)Uninstallation complete!$(NC)"

# Run target
.PHONY: run
run:
	@echo -e "$(BLUE)Running $(PROJECT)...$(NC)"
	@./$(BIN_DIR)/$(PROJECT)

# Development targets
.PHONY: format
format:
	@echo -e "$(BLUE)Formatting source code...$(NC)"
	@find src tests -name "*.zig" -exec $(ZIG) fmt {} \;
	@echo -e "$(GREEN)Formatting complete!$(NC)"

.PHONY: check-format
check-format:
	@echo -e "$(BLUE)Checking code formatting...$(NC)"
	@find src tests -name "*.zig" -exec $(ZIG) fmt --check {} \;
	@echo -e "$(GREEN)Formatting check passed!$(NC)"

# Documentation targets
.PHONY: docs
docts:
	@echo -e "$(BLUE)Generating documentation...$(NC)"
	@mkdir -p docs
	@$(ZIG) doc src/main.zig -o docs/index.html
	@echo -e "$(GREEN)Documentation generated in docs/!$(NC)"

# Analysis targets
.PHONY: analyze
analyze:
	@echo -e "$(BLUE)Analyzing code...$(NC)"
	@$(ZIG) analyze src/main.zig
	@echo -e "$(GREEN)Analysis complete!$(NC)"

# Version targets
.PHONY: version
version:
	@echo -e "$(BLUE)$(PROJECT) version:$(NC) $(VERSION)"

# Git targets
.PHONY: git-status
git-status:
	@echo -e "$(BLUE)Git status:$(NC)"
	@git status

.PHONY: git-log
git-log:
	@echo -e "$(BLUE)Recent git log:$(NC)"
	@git log --oneline -10

# Help target for specific commands
.PHONY: help-%
help-%:
	@echo -e "$(BLUE)Help for '$*':$(NC)"
	@$(MAKE) -p | grep -E "^$*:" | sed 's/^$*:/  /' | sort

# Phony targets to prevent make from creating files
.PHONY: build-release test test-sim test-utils test-all test-e2e test-e2e-verbose test-e2e-binary test-all-including-e2e clean install uninstall run format check-format docs analyze version git-status git-log help-%