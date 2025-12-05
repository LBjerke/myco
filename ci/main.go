package main

import (
	"context"
	"fmt"
	"os"
	"sync"

	"dagger.io/dagger"
)

func main() {
	ctx := context.Background()

	client, err := dagger.Connect(ctx, dagger.WithLogOutput(os.Stdout))
	if err != nil {
		panic(err)
	}
	defer client.Close()

		// --- Pipeline Configuration ---
	// Added Windows and macOS platforms
	platforms := []dagger.Platform{
		"linux/amd64",
		"linux/arm64",
		"darwin/amd64",
		"darwin/arm64",
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
			"lmdb",
			"linux-headers",
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

		var wg sync.WaitGroup
	
	// Create a buffered channel to hold errors from the 3 concurrent tasks
	errChan := make(chan error, 3)

	// Helper structure for our tasks
	type checkTask struct {
		Name string
		Cmd  []string
	}

	tasks := []checkTask{
		{Name: "Format", Cmd: []string{"zig", "fmt", ".", "--check"}},
		{Name: "Lint", Cmd: []string{"zig", "build", "lint"}},
		{Name: "Test", Cmd: []string{"zig", "build", "test"}},
	}

	fmt.Println("Starting Format, Lint, and Test stages concurrently...")

	for _, task := range tasks {
		wg.Add(1)
		go func(t checkTask) {
			defer wg.Done()
			fmt.Printf("Starting %s stage...\n", t.Name)
			
			// We use the main 'ctx' here, not a cancelable derived context.
			// .Sync() forces execution and returns an error if the exit code != 0
			_, err := runner.
				WithExec(t.Cmd).
				Sync(ctx)

			if err != nil {
				// Capture the error but don't panic yet
				errChan <- fmt.Errorf("[%s] failed: %w", t.Name, err)
			} else {
				fmt.Printf("[%s] passed!\n", t.Name)
			}
		}(task)
	}

	// Wait for all 3 to finish
	wg.Wait()
	close(errChan)

	// Collect all errors
	var collectedErrors []string
	for e := range errChan {
		collectedErrors = append(collectedErrors, e.Error())
	}

	// If there were errors, print them all and exit
	if len(collectedErrors) > 0 {
		fmt.Println("\n--- Check Stage Failures ---")
		for _, errMsg := range collectedErrors {
			fmt.Println(errMsg)
		}
		panic("One or more checks failed")
	}

	fmt.Println("All checks passed. Starting build stage...")

		// --- 5. Build Stage ---
	// Run builds for all platforms in parallel. Collect all errors.
	var buildWg sync.WaitGroup
	buildErrChan := make(chan error, len(platforms))

	for _, platform := range platforms {
		buildWg.Add(1)
		// Capture platform in the loop variable for the closure
		go func(p dagger.Platform) {
			defer buildWg.Done()
			
			arch, err := platformToZigTarget(p)
			if err != nil {
				buildErrChan <- fmt.Errorf("setup failed for %s: %w", p, err)
				return
			}

			fmt.Printf("Starting Build for %s (%s)...\n", p, arch)

			// Construct the build command
			buildCmd := base.
				WithMountedDirectory("/src", src).
				WithWorkdir("/src").
				WithExec([]string{"zig", "build", "-Dtarget=" + arch, "-Doptimize=ReleaseSafe"})

			outputBinary := buildCmd.File("/src/zig-out/bin/myco")
			outputPath := fmt.Sprintf("build/myco-%s", arch)

			// Perform the export (triggering the build)
			_, err = outputBinary.Export(ctx, outputPath)
			if err != nil {
				buildErrChan <- fmt.Errorf("build failed for %s: %w", p, err)
				return
			}
			
			fmt.Printf("Successfully built and exported binary for %s to %s\n", p, outputPath)
		}(platform)
	}

	buildWg.Wait()
	close(buildErrChan)

	// Collect and report Build errors
	var buildErrors []string
	for e := range buildErrChan {
		buildErrors = append(buildErrors, e.Error())
	}

	if len(buildErrors) > 0 {
		fmt.Println("\n--- Build Stage Failures ---")
		for _, errMsg := range buildErrors {
			fmt.Println(errMsg)
		}
		panic("One or more builds failed")
	}

	fmt.Println("All stages completed successfully!")
}

// Helper function remains the same
// Helper function to map Dagger/Docker platforms to Zig targets
func platformToZigTarget(platform dagger.Platform) (string, error) {
	switch platform {
	case "linux/amd64":
		return "x86_64-linux-musl", nil
	case "linux/arm64":
		return "aarch64-linux-musl", nil
	case "darwin/amd64":
		return "x86_64-macos", nil       // Intel Macs
	case "darwin/arm64":
		return "aarch64-macos", nil      // Apple Silicon
	default:
		return "", fmt.Errorf("unsupported platform: %s", platform)
	}
}
