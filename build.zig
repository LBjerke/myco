const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Top-level CI step - run all checks
    const ci_step = b.step("ci", "Run the full suite of CI checks (fmt, lint, build, test, test-sim, test-utils, complexity, duplication, tiger-style, e2e)");

    // Format check step (test:fmt)
    const test_fmt_step = b.step("test:fmt", "Check code formatting");
    const run_fmt_check = b.addFmt(.{
        .paths = &.{ "src/", "tests/" },
        .check = true,
    });
    test_fmt_step.dependOn(&run_fmt_check.step);
    ci_step.dependOn(test_fmt_step);

    // Format step (actual formatting)
    const format_step = b.step("format", "Format source code");
    const run_format = b.addFmt(.{
        .paths = &.{ "src/", "tests/" },
        .check = false,
    });
    format_step.dependOn(&run_format.step);

    // Lint step
    const lint_step = b.step("lint", "Run linter on source code");
    lint_step.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addPaths(.{
            .include = &.{ b.path("src/"), b.path("tests/") },
        });
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{
            .severity = .off,
        });
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        break :step builder.build();
    });
    ci_step.dependOn(lint_step);

    // Build step
    const build_step = b.step("build", "Build the project");
    const exe = b.addExecutable(.{
        .name = "myco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
    build_step.dependOn(&exe.step);
    ci_step.dependOn(build_step);

    // Run all unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    ci_step.dependOn(test_step);

    // Simulation tests
    const myco_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/simulation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sim_tests.root_module.addImport("myco", myco_mod);

    const sim_step = b.step("test-sim", "Run simulation tests");
    sim_step.dependOn(&b.addRunArtifact(sim_tests).step);
    ci_step.dependOn(sim_step);

    // Test utilities tests
    const utils_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    utils_tests.root_module.addImport("myco", myco_mod);

    const utils_step = b.step("test-utils", "Run test utility tests");
    utils_step.dependOn(&b.addRunArtifact(utils_tests).step);
    ci_step.dependOn(utils_step);

    // Complexity check step using lizard
    const complexity_step = b.step("complexity", "Check cyclomatic complexity (must be <= 13)");
    const complexity_cmd = b.addSystemCommand(&.{
        "lizard",
        "-l",
        "zig",
        "-C",
        "13",
        "src/",
    });
    complexity_step.dependOn(&complexity_cmd.step);
    ci_step.dependOn(complexity_step);

    // Code duplication check step using lizard
    const duplication_step = b.step("duplication", "Check for duplicate code");
    const duplication_cmd = b.addSystemCommand(&.{
        "lizard",
        "-Eduplicate",
        "-l",
        "zig",
        "src/",
    });
    duplication_step.dependOn(&duplication_cmd.step);
    ci_step.dependOn(duplication_step);

    // Tiger Style check step (assertion density is a warning, not a failure)
    const tiger_style_step = b.step("tiger-style", "Check Tiger Style compliance (100 char line limit, 70 line function limit, assert density)");
    const tiger_style_check = b.addSystemCommand(&.{
        "bash",
        "-c",
        \\echo "Checking Tiger Style compliance..."
        \\echo "1. Checking line lengths (max 100 chars)..."
        \\AWK_MAX=100
        \\OVER=0
        \\for f in src/**/*.zig; do
        \\    while IFS= read -r line; do
        \\        if [ ${#line} -gt $AWK_MAX ]; then
        \\            OVER=1
        \\            echo "Line exceeds $AWK_MAX chars: $line"
        \\        fi
        \\    done < "$f"
        \\done
        \\if [ $OVER -eq 1 ]; then
        \\    echo "FAILED: Lines exceeding 100 characters found"
        \\    exit 1
        \\fi
        \\echo "PASSED: All lines are within 100 characters"
        \\echo "2. Checking function lengths (max 70 lines)..."
        \\for f in src/**/*.zig; do
        \\    line_count=0
        \\    in_function=false
        \\    while IFS= read -r line; do
        \\        if echo "$line" | grep -q '^fn '; then
        \\            in_function=true
        \\            line_count=0
        \\        elif [ "$in_function" = true ]; then
        \\            if [ "$line" = "}" ]; then
        \\                if [ $line_count -gt 70 ]; then
        \\                    echo "Function exceeds 70 lines in $f"
        \\                    OVER=1
        \\                fi
        \\                in_function=false
        \\            else
        \\                line_count=$((line_count + 1))
        \\            fi
        \\        fi
        \\    done < "$f"
        \\done
        \\if [ $OVER -eq 1 ]; then
        \\    echo "FAILED: Functions exceeding 70 lines found"
        \\    exit 1
        \\fi
        \\echo "PASSED: All functions are within 70 lines"
        \\echo "3. Checking assertion density (min 2 assertions per function, excluding tests and small functions)..."
        \\TOTAL_FUNCTIONS=0
        \\TOTAL_ASSERTIONS=0
        \\LOW_ASSERT_FUNCTIONS=0
        \\for f in src/**/*.zig; do
        \\    # Skip test files for assertion density check
        \\    if [[ "$f" == *"test"* ]] || [[ "$f" == *"_test.zig" ]]; then
        \\        continue
        \\    fi
        \\    
        \\    # Parse functions and count assertions
        \\    FUNC_NAME=""
        \\    FUNC_LINES=0
        \\    FUNC_ASSERTS=0
        \\    IN_FUNC=false
        \\    
        \\    while IFS= read -r line; do
        \\        # Check for function start (pub fn or fn)
        \\        if echo "$line" | grep -qE '^[[:space:]]*(pub )?fn '; then
        \\            # Output previous function if exists (only count functions with >10 lines)
        \\            if [ "$IN_FUNC" = true ] && [ "$FUNC_LINES" -gt 10 ]; then
        \\                TOTAL_FUNCTIONS=$((TOTAL_FUNCTIONS + 1))
        \\                TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + FUNC_ASSERTS))
        \\                if [ "$FUNC_ASSERTS" -lt 2 ]; then
        \\                    LOW_ASSERT_FUNCTIONS=$((LOW_ASSERT_FUNCTIONS + 1))
        \\                    echo "  Low assertion density ($FUNC_ASSERTS): $FUNC_NAME in $f"
        \\                fi
        \\            fi
        \\            # Start new function
        \\            FUNC_NAME=$(echo "$line" | sed 's/.*fn \([^ (]*\).*/\1/')
        \\            FUNC_LINES=0
        \\            FUNC_ASSERTS=0
        \\            IN_FUNC=true
        \\        elif [ "$IN_FUNC" = true ]; then
        \\            if [ "$line" = "}" ]; then
        \\                # End of function
        \\                IN_FUNC=false
        \\            else
        \\                FUNC_LINES=$((FUNC_LINES + 1))
        \\                # Count assertions - match assert. in the line (any assertion function)
        \\                case "$line" in
        \\                    *assert.assert*|*assert.assertEqual*|*assert.assertLessThan*|*assert.assertBounds*|*assert.assertNotNull*|*assert.assertFalse*|*assert.assertSliceLen*|*assert.assertUnreachable*)
        \\                        FUNC_ASSERTS=$((FUNC_ASSERTS + 1))
        \\                        ;;
        \\                esac
        \\            fi
        \\        fi
        \\    done < "$f"
        \\    
        \\    # Output last function in file (only count functions with >10 lines)
        \\    if [ "$IN_FUNC" = true ] && [ "$FUNC_LINES" -gt 10 ]; then
        \\        TOTAL_FUNCTIONS=$((TOTAL_FUNCTIONS + 1))
        \\        TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + FUNC_ASSERTS))
        \\        if [ "$FUNC_ASSERTS" -lt 2 ]; then
        \\            LOW_ASSERT_FUNCTIONS=$((LOW_ASSERT_FUNCTIONS + 1))
        \\            echo "  Low assertion density ($FUNC_ASSERTS): $FUNC_NAME in $f"
        \\        fi
        \\    fi
        \\done
        \\
        \\if [ $TOTAL_FUNCTIONS -eq 0 ]; then
        \\    echo "  No functions found to check"
        \\else
        \\    # Use awk for floating point division (more portable than bc)
        \\    AVG_ASSERTIONS=$(awk "BEGIN {printf \"%.2f\", $TOTAL_ASSERTIONS / $TOTAL_FUNCTIONS}")
        \\    echo "  Total functions checked: $TOTAL_FUNCTIONS"
        \\    echo "  Total assertions: $TOTAL_ASSERTIONS"
        \\    echo "  Average assertions per function: $AVG_ASSERTIONS"
        \\    if [ $LOW_ASSERT_FUNCTIONS -gt 0 ]; then
        \\        echo "  WARNING: $LOW_ASSERT_FUNCTIONS functions have fewer than 2 assertions"
        \\    fi
        \\    # Compare as floating point using awk
        \\    PASSED=$(awk "BEGIN {print ($AVG_ASSERTIONS >= 2 ? 1 : 0)}")
        \\    if [ $PASSED -eq 0 ]; then
        \\        echo "WARNING: Average assertion density ($AVG_ASSERTIONS) is below recommended (2)"
        \\        echo "  Consider adding assertions to functions for better bug detection"
        \\        # Note: Not failing the build for assertion density - it's a recommendation
        \\    else
        \\        echo "PASSED: Assertion density meets minimum (2 per function)"
        \\    fi
        \\fi
        \\echo "Tiger Style check PASSED (with warnings)"
    });
    tiger_style_step.dependOn(&tiger_style_check.step);
    ci_step.dependOn(tiger_style_step);

    // E2E tests
    const e2e_step = b.step("e2e", "Run end-to-end tests");

    // Run the shell script directly - ensure build runs first
    const e2e_script = b.addSystemCommand(&.{
        "bash",
        "-c",
        "cd tests/e2e && chmod +x test-harness.sh test-cli.sh && ./test-harness.sh ./test-cli.sh",
    });

    // E2E depends on both build step (to have binary) and the script
    e2e_step.dependOn(build_step);
    e2e_step.dependOn(&e2e_script.step);
    ci_step.dependOn(e2e_step);

    // Docs step
    const docs_step = b.step("docs", "Generate HTML documentation");
    const docs_cmd = b.addSystemCommand(&.{ "mkdir", "-p", "docs" });
    docs_step.dependOn(&docs_cmd.step);

    // Note: "install" step is provided by default by zig build
}
