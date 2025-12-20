package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"dagger.io/dagger"
)

type stageResult struct {
	Name     string
	Duration time.Duration
	Err      error
}

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
	src := client.Host().Directory(".", dagger.HostDirectoryOpts{
		Include: []string{
			"build.zig",
			"build.zig.zon",
			"src",
			"tests",
			"ci",
			"scripts",
			"docs",
			"Makefile",
			"README.md",
			"go.mod",
			"go.sum",
			"flake.nix",
			"flake.lock",
			".gitmodules",
		},
		Exclude: []string{
			"zig-cache",
			"zig-out",
			"tmp",
			"build",
		},
	})

	fmt.Println("Creating Alpine build environment...")

	enginePlatform, err := client.DefaultPlatform(ctx)
	if err != nil {
		panic(fmt.Errorf("failed to detect engine platform: %w", err))
	}

	zigBuildPlatform := "x86_64-linux"
	switch enginePlatform {
	case "linux/amd64":
		zigBuildPlatform = "x86_64-linux"
	case "linux/arm64":
		zigBuildPlatform = "aarch64-linux"
	default:
		fmt.Printf("Warning: unknown platform %q, defaulting Zig download to x86_64\n", enginePlatform)
	}

	indexURL := "https://ziglang.org/download/index.json"

	base := client.Container().
		From("alpine:3.20").
		WithExec([]string{
			"apk", "add", "--no-cache",
			"build-base",
			"bash",
			"wget", "xz", "curl",
			"coreutils", // Installs 'timeout'
			"ca-certificates",
			"procps", // pkill/ps used by smoke script
			"python3",
		}).
		// Install the pinned Zig toolchain (matches build.zig.zon minimum_zig_version).
		WithExec([]string{
			"sh", "-c",
			fmt.Sprintf(`set -euo pipefail
cd /tmp
if ! fetch_url=$(python3 - <<'PY'
import json, urllib.request, sys
platform = "%s"
url = ""
with urllib.request.urlopen("%s") as resp:
    data = json.load(resp)
    preferred = [k for k in data.keys() if k.startswith("0.15.")]
    preferred.sort(reverse=True)
    for key in preferred:
        candidate = data.get(key, {}).get(platform, {}).get("tarball", "")
        if candidate:
            url = candidate
            break
    if not url:
        url = data.get("master", {}).get(platform, {}).get("tarball", "")
print(url)
PY
); then
  echo "failed to query zig index"
  exit 1
fi
if [ -z "$fetch_url" ]; then
  echo "no tarball URL found for platform"
  exit 1
fi
echo "resolved zig tarball: $fetch_url"
if wget -O zig.tar.xz "$fetch_url"; then
  ls -lh zig.tar.xz
  extract_dir=$(tar tf zig.tar.xz | head -1 || true)
  extract_dir=${extract_dir%%/*}
  tar xf zig.tar.xz
  mv "$extract_dir" /opt/zig
  ln -sf /opt/zig/zig /usr/local/bin/zig
else
  echo "wget failed, falling back to apk zig"
  apk add --no-cache zig
fi
ZIG_BIN=/usr/local/bin/zig
if [ ! -x "$ZIG_BIN" ]; then
  ZIG_BIN=$(command -v zig)
fi
"$ZIG_BIN" version
`, zigBuildPlatform, indexURL),
		}).
		WithEnvVariable("ZIG_LOCAL_CACHE_DIR", "/tmp/zig-cache").
		WithEnvVariable("ZIG_GLOBAL_CACHE_DIR", "/tmp/zig-cache")

	runner := base.
		WithMountedDirectory("/src", src).
		WithWorkdir("/src")

	var results []stageResult

	type checkTask struct {
		Name string
		Cmd  []string
	}

	tasks := []checkTask{
		{Name: "Format", Cmd: []string{"zig", "fmt", "src", "tests", "build.zig", "--check"}},
		{Name: "Build Check", Cmd: []string{"zig", "build"}},
		{Name: "Unit Tests", Cmd: []string{"zig", "build", "test"}},
	}

	fmt.Println("Running checks sequentially (timed)...")

	for _, task := range tasks {
		start := time.Now()
		fmt.Printf("Starting %s stage...\n", task.Name)
		_, err := runner.WithExec(task.Cmd).Sync(ctx)
		dur := time.Since(start)
		if err != nil {
			fmt.Printf("[%s] failed (%s): %v\n", task.Name, dur, err)
			results = append(results, stageResult{Name: task.Name, Duration: dur, Err: err})
			printSummaryAndExit(results)
			return
		}
		fmt.Printf("[%s] passed! (%s)\n", task.Name, dur)
		results = append(results, stageResult{Name: task.Name, Duration: dur})
	}

	// --- Integration Test ---
	{
		fmt.Println("Starting Integration Test stage (matrix smoke tests)...")

		integrationScript := `
            set -euo pipefail

            # Shared secrets for encrypted packet + transport during CI smoke.
            PACKET_KEY=${PACKET_KEY:-ci-packet-key}
            PACKET_EPOCH=${PACKET_EPOCH:-1}
            TRANSPORT_PSK=${TRANSPORT_PSK:-ci-transport-psk}
            export PACKET_KEY PACKET_EPOCH TRANSPORT_PSK
            unset MYCO_PACKET_PLAINTEXT MYCO_PACKET_ALLOW_PLAINTEXT MYCO_TRANSPORT_PLAINTEXT MYCO_TRANSPORT_ALLOW_PLAINTEXT

            echo "--- [1] Build ---"
            export ZIG_LOCAL_CACHE_DIR=/tmp/zig-cache
            export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
            zig build -Doptimize=ReleaseFast

            echo "--- [2] Matrix smoke tests ---"
            chmod +x scripts/local_two_node.sh

            matrix=${SMOKE_MATRIX:-"5:10,8:10"}
            IFS=',' read -r -a runs <<< "$matrix"

            results="| nodes | services | wall_time_s | converged |\n|------|----------|-------------|-----------|\n"
            any_fail=0

            for entry in "${runs[@]}"; do
              nodes=${entry%%:*}
              services=${entry##*:}
              if [ -z "$nodes" ] || [ -z "$services" ]; then
                echo "Skipping malformed matrix entry: $entry"
                continue
              fi

              echo ">>> Running smoke: ${nodes} nodes, ${services} services each"
              start=$(date +%s)
              quiet_status=0
              if [ "$nodes" -gt 20 ]; then
                quiet_status=1
              fi

              if PORT_BASE=17777 \
                 NODES=$nodes \
                 SERVICES_PER_NODE=$services \
                 QUIET_STATUS=$quiet_status \
                 ZIG_LOCAL_CACHE_DIR=$ZIG_LOCAL_CACHE_DIR \
                 ZIG_GLOBAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR \
                 scripts/local_two_node.sh; then
                converged=true
              else
                converged=false
                any_fail=1
              fi
              wall=$(( $(date +%s) - start ))
              results+="| ${nodes} | ${services} | ${wall} | ${converged} |\n"
            done

            echo "=== Smoke Matrix Results ==="
            printf "%b" "$results"

            if [ "$any_fail" -ne 0 ]; then
              exit 1
            fi
        `

		start := time.Now()
		_, err := runner.
			WithExec([]string{"bash", "-c", integrationScript}).
			Sync(ctx)
		dur := time.Since(start)
		if err != nil {
			fmt.Printf("[Integration Test] failed (%s): %v\n", dur, err)
			results = append(results, stageResult{Name: "Integration Test", Duration: dur, Err: err})
			printSummaryAndExit(results)
			return
		}
		fmt.Printf("[Integration Test] passed! (%s)\n", dur)
		results = append(results, stageResult{Name: "Integration Test", Duration: dur})
	}

	fmt.Println("All checks passed. Starting build stage (sequential, timed)...")

	for _, platform := range platforms {
		target, err := platformToZigTarget(platform)
		if err != nil {
			printSummaryAndExit(append(results, stageResult{Name: string(platform), Err: err}))
			return
		}

		stageName := fmt.Sprintf("Build %s (%s)", platform, target)
		start := time.Now()
		fmt.Printf("Starting %s...\n", stageName)

		buildCmd := base.
			WithMountedDirectory("/src", src).
			WithWorkdir("/src").
			WithExec([]string{"zig", "build", "-Dtarget=" + target, "-Doptimize=ReleaseSmall"})

		outputBinary := buildCmd.File("/src/zig-out/bin/myco")
		outputPath := fmt.Sprintf("build/myco-%s", target)

		_, err = outputBinary.Export(ctx, outputPath)
		dur := time.Since(start)
		if err != nil {
			fmt.Printf("[%s] failed (%s): %v\n", stageName, dur, err)
			printSummaryAndExit(append(results, stageResult{Name: stageName, Duration: dur, Err: err}))
			return
		}

		fmt.Printf("Built %s in %s\n", outputPath, dur)
		results = append(results, stageResult{Name: stageName, Duration: dur})
	}

	printSummary(results)
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

func printSummary(results []stageResult) {
	fmt.Println("\n--- Stage Durations ---")
	var slowest stageResult
	for i, r := range results {
		status := "OK"
		if r.Err != nil {
			status = "FAIL"
		}
		fmt.Printf("%-25s %10s [%s]\n", r.Name, r.Duration, status)
		if i == 0 || r.Duration > slowest.Duration {
			slowest = r
		}
	}
	fmt.Printf("Slowest stage: %s (%s)\n", slowest.Name, slowest.Duration)
}

func printSummaryAndExit(results []stageResult) {
	printSummary(results)
	panic("Checks failed")
}
