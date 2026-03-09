const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run all tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

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
}
