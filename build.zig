const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Define the 'myco' Library Module (src/lib.zig)
    const myco_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
    });

    // --- TEST 1: SIMULATION ---
    const sim_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/simulation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sim_test.root_module.addImport("myco", myco_module);
    const run_sim_test = b.addRunArtifact(sim_test);
    const test_sim_step = b.step("test-sim", "Run the Phase 5 Grand Simulation");
    test_sim_step.dependOn(&run_sim_test.step);

    // --- TEST 2: ENGINE ---
    const engine_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    engine_test.root_module.addImport("myco", myco_module);
    const run_engine_test = b.addRunArtifact(engine_test);
    const test_engine_step = b.step("test-engine", "Test Systemd/Nix Engine");
    test_engine_step.dependOn(&run_engine_test.step);

    // --- TEST 3: CLI ---
    const cli_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_test.root_module.addImport("myco", myco_module);
    const run_cli_test = b.addRunArtifact(cli_test);
    const test_cli_step = b.step("test-cli", "Test CLI Scaffolding");
    test_cli_step.dependOn(&run_cli_test.step);

    // --- TEST 4: CRDT SYNC ---
    const crdt_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/sync_crdt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    crdt_test.root_module.addImport("myco", myco_module);
    const run_crdt_test = b.addRunArtifact(crdt_test);
    const test_crdt_step = b.step("test-crdt", "Test CRDT Sync Logic");
    test_crdt_step.dependOn(&run_crdt_test.step);

    // --- MAIN EXECUTABLE ---
    // FIX: Wrap source config in root_module
    const exe = b.addExecutable(.{
        .name = "myco",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // Import the library module so main.zig can do @import("myco")
    exe.root_module.addImport("myco", myco_module);
    
    b.installArtifact(exe);
}
