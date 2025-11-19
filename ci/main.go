package main

import (
	"context"
	"fmt"
	"os"

	"dagger.io/dagger"
	"golang.org/x/sync/errgroup"
)

func main() {
	ctx := context.Background()

	client, err := dagger.Connect(ctx, dagger.WithLogOutput(os.Stdout))
	if err != nil {
		panic(err)
	}
	defer client.Close()

	// --- Pipeline Configuration ---
	//zigVersion := "0.15.2"
	platforms := []dagger.Platform{
		"linux/amd64",
		"linux/arm64",
	}
	src := client.Host().Directory(".")

	// --- 1. Create a Reusable Alpine-based Build Environment ---
	// This container will have all our C dependencies and the correct Zig version installed.
	// It will be cached by Dagger and only rebuilt if this code changes.
	fmt.Println("Creating Alpine build environment...")

	base := client.Container().
		// Start from a standard, lightweight Alpine image
		From("alpine:edge").
		// Install all C library dependencies (-dev packages provide headers) and tools
		WithExec([]string{
			"apk", "update",
		}).
		WithExec([]string{
			"apk", "add", "--no-cache",
			"build-base",   // For gcc, make, etc.
			"pkgconf",      // pkg-config
			"git",          // For libgit2 source or tools if needed
			"zeromq-dev",   // libzmq
			"czmq-dev",     // libczmq
			"libssh2-dev",  // libssh2
			"openssl-dev",  // libssl
			"wget",         // To download Zig
			"xz",           // To decompress the Zig tarball
			"zig",
		})
		// Download and install the specific Zig version
		// This is the key change. We create a new base that includes the source code.
	// All subsequent steps will start FROM this container.
	runner := base.
		WithMountedDirectory("/src", src).
		WithWorkdir("/src")

	eg, gCtx := errgroup.WithContext(ctx)

	// --- 3. Lint Stage ---
	eg.Go(func() error {
		fmt.Println("Starting Lint stage...")
		// Start from our new 'runner' base
		_, err := runner.
			WithExec([]string{"zig", "fmt", ".", "--check"}).
			ExitCode(gCtx)
		if err != nil {
			return fmt.Errorf("lint stage failed: %w", err)
		}
		fmt.Println("Lint stage passed!")
		return nil
	})

	// --- 4. Test Stage ---
	eg.Go(func() error {
		fmt.Println("Starting Test stage...")
		// Also start from the 'runner' base
		_, err := runner.
			WithExec([]string{"zig", "build", "test"}).
			ExitCode(gCtx)
		if err != nil {
			return fmt.Errorf("test stage failed: %w", err)
		}
		fmt.Println("Test stage passed!")
		return nil
	})

	if err := eg.Wait(); err != nil {
		panic(fmt.Errorf("pre-build stages failed: %w", err))
	}

	fmt.Println("Linting and testing complete. Starting build stage...")

	buildEg, buildCtx := errgroup.WithContext(ctx)

	// --- 5. Build Stage ---
	for _, platform := range platforms {
		platform := platform
		buildEg.Go(func() error {
			arch, err := platformToZigTarget(platform)
			if err != nil {
				return err
			}
			fmt.Printf("Starting Build for %s (%s)...\n", platform, arch)
			
			// For cross-compilation, we still need to start from the `base` and
			// mount the source, as the runner is for the native platform.
			// However, Zig's cross-compilation is self-contained, so this is fine.
			buildCmd := base.
				WithMountedDirectory("/src", src).
				WithWorkdir("/src").
				WithExec([]string{"zig", "build", "-Dtarget=" + arch, "-Doptimize=ReleaseSafe"})

			outputBinary := buildCmd.File("/src/zig-out/bin/Orchestrator")
			outputPath := fmt.Sprintf("build/Orchestrator-%s", arch)

			_, err = outputBinary.Export(buildCtx, outputPath)
			if err != nil {
				return fmt.Errorf("failed to export binary for %s: %w", platform, err)
			}
			fmt.Printf("Successfully built and exported binary for %s to %s\n", platform, outputPath)
			return nil
		})
	}

	if err := buildEg.Wait(); err != nil {
		panic(fmt.Errorf("build stage failed: %w", err))
	}

	fmt.Println("All stages completed successfully!")
}

// Helper function remains the same
func platformToZigTarget(platform dagger.Platform) (string, error) {
	switch platform {
	case "linux/amd64":
		return "x86_64-linux-musl", nil
	case "linux/arm64":
		return "aarch64-linux-musl", nil
	default:
		return "", fmt.Errorf("unsupported platform: %s", platform)
	}
}
