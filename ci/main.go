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

	platforms := []dagger.Platform{
		"linux/amd64",
		"linux/arm64",
	}
	src := client.Host().Directory(".")

	fmt.Println("Creating Alpine build environment...")

	base := client.Container().
		From("alpine:edge").
		WithExec([]string{
			"apk", "add", "--no-cache",
			"build-base",
			"bash",
			"wget", "xz", "curl",
			"zig",
			"coreutils", // Installs 'timeout'
		})

	runner := base.
		WithMountedDirectory("/src", src).
		WithWorkdir("/src")

	var wg sync.WaitGroup
	errChan := make(chan error, 5)

	type checkTask struct {
		Name string
		Cmd  []string
	}

	tasks := []checkTask{
		{Name: "Format", Cmd: []string{"zig", "fmt", ".", "--check"}},
		{Name: "Build Check", Cmd: []string{"zig", "build"}},
		{Name: "Unit Tests", Cmd: []string{"zig", "build", "test"}},
	}

	fmt.Println("Starting Format, Test, and Integration stages concurrently...")

	for _, task := range tasks {
		wg.Add(1)
		go func(t checkTask) {
			defer wg.Done()
			fmt.Printf("Starting %s stage...\n", t.Name)
			_, err := runner.WithExec(t.Cmd).Sync(ctx)
			if err != nil {
				errChan <- fmt.Errorf("[%s] failed: %w", t.Name, err)
			} else {
				fmt.Printf("[%s] passed!\n", t.Name)
			}
		}(task)
	}

	// --- 3. The Integration Test (UPDATED) ---
	wg.Add(1)
	go func() {
		defer wg.Done()
		fmt.Println("Starting Integration Test stage...")

		integrationScript := `
            set -e

            echo "--- [1] Environment Setup ---"
            # Mock 'nix'
            echo '#!/bin/bash' > /usr/bin/nix
            echo 'echo /nix/store/mock-output-path' >> /usr/bin/nix
            chmod +x /usr/bin/nix

            # Mock 'systemctl'
            echo '#!/bin/bash' > /usr/bin/systemctl
            exit 0 
            chmod +x /usr/bin/systemctl

            # Create Directories
            mkdir -p /run/systemd/system
            mkdir -p /var/lib/myco
            mkdir -p services

            # Create Test Config
            # We name it 'test-service' so we expect '127.0.0.1 test-service' in /etc/hosts
            echo '{"name":"test-service","package":"nixpkgs#hello","port":8080}' > services/test.json

            echo "--- [2] Building Binary ---"
            zig build

            echo "--- [3] Running Myco (Mocked) ---"
            export WATCHDOG_USEC=5000000
            
            # Run for 10s. It will update hosts loop every 5s.
            timeout 10s ./zig-out/bin/myco up || true

            echo "--- [4] Verification ---"
            
            echo "Checking Unit File..."
            if [ -f "/run/systemd/system/myco-test-service.service" ]; then
                echo "[OK] Unit file exists."
            else
                echo "[FAIL] Unit file missing."
                exit 1
            fi

            echo "Checking /etc/hosts injection..."
            # Print for debug
            cat /etc/hosts
            
            # Grep for the marker and the service
            if grep -q "# --- MYCO START ---" /etc/hosts; then
                echo "[OK] Myco block found in /etc/hosts."
            else
                echo "[FAIL] Myco block missing from /etc/hosts."
                exit 1
            fi

            if grep -q "127.0.0.1.*test-service" /etc/hosts; then
                echo "[OK] Service entry found in /etc/hosts."
            else
                echo "[FAIL] Service entry 'test-service' missing from /etc/hosts."
                exit 1
            fi
        `

		_, err := runner.
			WithExec([]string{"bash", "-c", integrationScript}).
			Sync(ctx)

		if err != nil {
			errChan <- fmt.Errorf("[Integration Test] failed: %w", err)
		} else {
			fmt.Printf("[Integration Test] passed!\n")
		}
	}()

	wg.Wait()
	close(errChan)

	var collectedErrors []string
	for e := range errChan {
		collectedErrors = append(collectedErrors, e.Error())
	}

	if len(collectedErrors) > 0 {
		fmt.Println("\n--- Check Stage Failures ---")
		for _, errMsg := range collectedErrors {
			fmt.Println(errMsg)
		}
		panic("Checks failed")
	}

	fmt.Println("All checks passed. Starting build stage...")

	// --- 4. Build Stage ---
	var buildWg sync.WaitGroup
	buildErrChan := make(chan error, len(platforms))

	for _, platform := range platforms {
		buildWg.Add(1)
		go func(p dagger.Platform) {
			defer buildWg.Done()

			target, err := platformToZigTarget(p)
			if err != nil {
				buildErrChan <- fmt.Errorf("setup failed for %s: %w", p, err)
				return
			}

			fmt.Printf("Starting Build for %s (%s)...\n", p, target)

			buildCmd := base.
				WithMountedDirectory("/src", src).
				WithWorkdir("/src").
				WithExec([]string{"zig", "build", "-Dtarget=" + target, "-Doptimize=ReleaseSmall"})

			outputBinary := buildCmd.File("/src/zig-out/bin/myco")
			outputPath := fmt.Sprintf("build/myco-%s", target)

			_, err = outputBinary.Export(ctx, outputPath)
			if err != nil {
				buildErrChan <- fmt.Errorf("build failed for %s: %w", p, err)
				return
			}

			fmt.Printf("Built %s\n", outputPath)
		}(platform)
	}

	buildWg.Wait()
	close(buildErrChan)

	var buildErrors []string
	for e := range buildErrChan {
		buildErrors = append(buildErrors, e.Error())
	}

	if len(buildErrors) > 0 {
		fmt.Println("\n--- Build Stage Failures ---")
		for _, errMsg := range buildErrors {
			fmt.Println(errMsg)
		}
		panic("Builds failed")
	}

	fmt.Println("🚀 Pipeline completed successfully!")
}

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
