package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"dagger.io/dagger"
)

func main() {
	timeout := 7 * time.Minute
	if value := os.Getenv("MYCO_CI_TIMEOUT_MIN"); value != "" {
		if minutes, err := strconv.Atoi(value); err == nil && minutes > 0 {
			timeout = time.Duration(minutes) * time.Minute
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	client, err := dagger.Connect(ctx, dagger.WithLogOutput(os.Stdout))
	if err != nil {
		panic(err)
	}
	defer func() {
		done := make(chan struct{})
		go func() {
			client.Close()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(30 * time.Second):
			fmt.Println("warning: dagger close timed out; forcing exit")
		}
	}()

	platforms := []dagger.Platform{
		"linux/amd64",
		"linux/arm64",
	}
	src := client.Host().Directory(".", dagger.HostDirectoryOpts{
		Exclude: []string{
			".git/",
			".zig-cache/",
			"zig-cache/",
			"zig-out/",
			"tmp/",
		},
		Gitignore: true,
	})

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

	pollMs := os.Getenv("MYCO_POLL_MS")
	if pollMs == "" {
		pollMs = "100"
	}
	syncTicks := os.Getenv("MYCO_SYNC_TICKS")
	if syncTicks == "" {
		syncTicks = "5"
	}
	runner := base.
		WithMountedDirectory("/src", src).
		WithWorkdir("/src").
		WithEnvVariable("MYCO_POLL_MS", pollMs).
		WithEnvVariable("MYCO_SYNC_TICKS", syncTicks)

	var wg sync.WaitGroup
	errChan := make(chan error, 6)

	type checkTask struct {
		Name string
		Cmd  []string
	}

	tasks := []checkTask{
		{Name: "Format", Cmd: []string{"zig", "fmt", ".", "--check", "--exclude", ".zig-cache", "--exclude", "zig-cache", "--exclude", "zig-out"}},
		{Name: "Build Check", Cmd: []string{"zig", "build"}},
		{Name: "Unit Tests", Cmd: []string{"bash", "-c", `
set -e
export ZIG_GLOBAL_CACHE_DIR=/src/zig-cache
export ZIG_LOCAL_CACHE_DIR=/src/zig-cache
# Aggregates the file-level tests under a single root with module path = /src.
plain_tests=(
  src/plain_tests.zig
)
module_tests=(
  tests/sync_crdt.zig
  tests/bench_packet_crypto.zig
  tests/cli.zig
  tests/engine.zig
)
for t in "${plain_tests[@]}"; do
  echo "==> zig test ${t}"
  timeout 300 zig test -lc --dep build_options -Mroot="${t}" -Mbuild_options=src/build_options.zig
done
for t in "${module_tests[@]}"; do
  echo "==> zig test ${t} (with myco module)"
  timeout 300 zig test -lc --dep build_options --dep myco -Mroot="${t}" -Mbuild_options=src/build_options.zig --dep build_options -Mmyco=src/lib.zig
done
`}},
	}

	fmt.Println("Starting Format, Test, Integration, and Cluster Smoke stages concurrently...")

	for _, task := range tasks {
		wg.Add(1)
		go func(t checkTask) {
			defer wg.Done()
			fmt.Printf("Starting %s stage...\n", t.Name)
			timeoutCmd := append([]string{"timeout", "900"}, t.Cmd...)
			_, err := runner.WithExec(timeoutCmd).Sync(ctx)
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
			WithExec([]string{"timeout", "900", "bash", "-c", integrationScript}).
			Sync(ctx)

		if err != nil {
			errChan <- fmt.Errorf("[Integration Test] failed: %w", err)
		} else {
			fmt.Printf("[Integration Test] passed!\n")
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		fmt.Println("Starting Cluster Smoke stage...")

		err := runClusterSmoke(ctx, runner)
		if err != nil {
			errChan <- fmt.Errorf("[Cluster Smoke] failed: %w", err)
		} else {
			fmt.Printf("[Cluster Smoke] passed!\n")
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

	if os.Getenv("RUN_PLATFORM_BUILD") != "1" {
		fmt.Println("Skipping multi-platform build stage (set RUN_PLATFORM_BUILD=1 to enable).")
		return
	}

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

func runClusterSmoke(ctx context.Context, runner *dagger.Container) error {
	preset := strings.ToLower(os.Getenv("MYCO_SMOKE_PRESET"))
	nodes := 5
	jobs := 2
	nodesFromEnv := false
	jobsFromEnv := false
	if value := os.Getenv("MYCO_SMOKE_NODES"); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil && parsed > 0 {
			nodes = parsed
			nodesFromEnv = true
		}
	}
	if value := os.Getenv("MYCO_SMOKE_JOBS_PER_NODE"); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil && parsed > 0 {
			jobs = parsed
			jobsFromEnv = true
		}
	}
	switch preset {
	case "stress":
		if !nodesFromEnv {
			nodes = 10
		}
		if !jobsFromEnv {
			jobs = 40
		}
	case "max":
		if !nodesFromEnv {
			nodes = 16
		}
		if !jobsFromEnv {
			jobs = 32
		}
	case "", "default":
	default:
		fmt.Printf("Unknown MYCO_SMOKE_PRESET=%q; using explicit/default values.\n", preset)
	}

	if preset == "" {
		fmt.Printf("Running cluster smoke (nodes=%d, jobs=%d)...\n", nodes, jobs)
	} else {
		fmt.Printf("Running cluster smoke (preset=%s, nodes=%d, jobs=%d)...\n", preset, nodes, jobs)
	}

	maxWait := os.Getenv("MYCO_SMOKE_MAX_WAIT_SEC")
	if maxWait == "" {
		total := nodes * jobs
		switch {
		case total >= 400:
			maxWait = "900"
		case total >= 300:
			maxWait = "720"
		case total >= 200:
			maxWait = "600"
		case total >= 150:
			maxWait = "600"
		case total >= 100:
			maxWait = "480"
		case total >= 50:
			maxWait = "360"
		default:
			maxWait = "240"
		}
	}
clusterScript := `
set -euo pipefail

# Mock nix/systemctl so smoke deploys don't require real system services.
echo '#!/bin/sh' > /usr/bin/nix
echo 'echo /nix/store/mock-output-path' >> /usr/bin/nix
chmod +x /usr/bin/nix
echo '#!/bin/sh' > /usr/bin/systemctl
echo 'exit 0' >> /usr/bin/systemctl
chmod +x /usr/bin/systemctl

BIN=/src/zig-out/bin/myco
STATE=/tmp/myco-smoke
NODE_COUNT="${MYCO_SMOKE_NODES:-5}"
SERVICES_PER_NODE="${MYCO_SMOKE_JOBS_PER_NODE:-2}"
SMOKE_OPTIMIZE="${MYCO_SMOKE_OPTIMIZE:-ReleaseFast}"
NODE_NAMES=()
for i in $(seq 1 "${NODE_COUNT}"); do
  NODE_NAMES+=("n${i}")
done
PORT_BASE=17777
NODE_COUNT=${#NODE_NAMES[@]}
TOTAL_SERVICES=$((NODE_COUNT * SERVICES_PER_NODE))
MAX_WAIT_SEC="${MYCO_SMOKE_MAX_WAIT_SEC:-240}"
MAX_CHECKS=$(( (MAX_WAIT_SEC + 1) / 2 ))
STATUS_TIMEOUT_SEC="${MYCO_SMOKE_STATUS_TIMEOUT_SEC:-5}"
start_ts=$(date +%s)
inject_start_ts=0
inject_end_ts=0
converged_ts=0
phase="init"

PIDS=()
DEPLOY_PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do
    kill "$p" >/dev/null 2>&1 || true
  done
}
dump_logs() {
  echo "==> Log tails (myco.log)"
  for node in "${NODE_NAMES[@]}"; do
    echo "--- ${node} ---"
    tail -n 200 "${STATE}/${node}/myco.log" || true
    echo ""
  done
}
on_exit() {
  status=$?
  trap - EXIT
  cleanup
  end_ts=$(date +%s)
  echo "==> Cluster smoke wall time: $((end_ts - start_ts))s"
  if [ "$inject_start_ts" -gt 0 ] && [ "$converged_ts" -eq 0 ]; then
    echo "==> Time since job injection started: $((end_ts - inject_start_ts))s"
  fi
  if [ "$inject_end_ts" -gt 0 ] && [ "$converged_ts" -eq 0 ]; then
    echo "==> Time since job injection finished: $((end_ts - inject_end_ts))s"
  fi
  if [ "$status" -ne 0 ]; then
    dump_logs
  fi
  exit "$status"
}
trap on_exit EXIT

check_daemons() {
  local dead=0
  for idx in "${!PIDS[@]}"; do
    local pid="${PIDS[$idx]}"
    local node="${NODE_NAMES[$idx]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[FAIL] daemon for ${node} (pid ${pid}) died during ${phase}"
      dead=1
    fi
  done
  if [ "$dead" -ne 0 ]; then
    echo "==> Daemon process snapshot"
    ps -o pid,stat,comm -p "${PIDS[@]}" 2>/dev/null || true
    return 1
  fi
  return 0
}

rm -rf "${STATE}"
mkdir -p "${STATE}"
for node in "${NODE_NAMES[@]}"; do
  mkdir -p "${STATE}/${node}"
done

echo "==> Building smoke binary (optimize=${SMOKE_OPTIMIZE})..."
zig build -Doptimize="${SMOKE_OPTIMIZE}"

start_node() {
  name="$1"
  port="$2"
  nid="$3"
  dir="${STATE}/${name}"
  sock="${dir}/myco.sock"
  log="${dir}/myco.log"
  MYCO_STATE_DIR="$dir" MYCO_PORT="$port" MYCO_NODE_ID="$nid" MYCO_UDS_PATH="$sock" MYCO_TRANSPORT_ALLOW_PLAINTEXT=1 MYCO_SMOKE_SKIP_EXEC=1 "${BIN}" daemon >"$log" 2>&1 &
  PIDS+=("$!")
}

echo "==> Starting nodes..."
phase="start"
for idx in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[$idx]}"
  start_node "$node" $((PORT_BASE + idx)) $((idx + 1))
done

sleep 2
phase="post-start"
check_daemons || exit 1

echo "==> Fetching pubkeys..."
PUBS=()
for idx in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[$idx]}"
  dir="${STATE}/${node}"
  sock="${dir}/myco.sock"
  nid=$((idx + 1))
  PUBS[$idx]=$(MYCO_STATE_DIR="$dir" MYCO_UDS_PATH="$sock" MYCO_NODE_ID="$nid" "${BIN}" pubkey)
done

echo "==> Wiring peers..."
for i in "${!NODE_NAMES[@]}"; do
  src="${NODE_NAMES[$i]}"
  src_dir="${STATE}/${src}"
  src_sock="${src_dir}/myco.sock"
  for j in "${!NODE_NAMES[@]}"; do
    [ "$i" -eq "$j" ] && continue
    MYCO_STATE_DIR="$src_dir" MYCO_UDS_PATH="$src_sock" "${BIN}" peer add "${PUBS[$j]}" "127.0.0.1:$((PORT_BASE + j))"
  done
done

echo "==> Preparing services..."
service_id=1
for node in "${NODE_NAMES[@]}"; do
  out="/tmp/myco-svc-${node}.json"
  echo "[" > "$out"
  for i in $(seq 1 "${SERVICES_PER_NODE}"); do
cat >> "$out" <<JSON
{
  "id": ${service_id},
  "name": "hello-${node}-${i}",
  "flake_uri": "github:example/hello-${node}-${i}",
  "exec_name": "run"
}
JSON
    service_id=$((service_id + 1))
    if [ "$i" -lt "${SERVICES_PER_NODE}" ]; then
      echo "," >> "$out"
    fi
  done
  echo "]" >> "$out"
done

echo "==> Deploying services to each node..."
phase="deploy"
inject_start_ts=$(date +%s)
for node in "${NODE_NAMES[@]}"; do
  (
    dir="${STATE}/${node}"
    sock="${dir}/myco.sock"
    cp "/tmp/myco-svc-${node}.json" "${dir}/myco.json"
    (cd "$dir" && MYCO_STATE_DIR="$dir" MYCO_UDS_PATH="$sock" "${BIN}" deploy) || true
  ) &
  DEPLOY_PIDS+=("$!")
done
for p in "${DEPLOY_PIDS[@]}"; do
  wait "$p"
done
inject_end_ts=$(date +%s)
phase="post-deploy"
check_daemons || exit 1

echo "==> Waiting for convergence (expect ${TOTAL_SERVICES} services per node, max ${MAX_WAIT_SEC}s)..."
all_ok=0
for i in $(seq 1 "${MAX_CHECKS}"); do
  phase="converge"
  check_daemons || exit 1
  all_ok=1
  for node in "${NODE_NAMES[@]}"; do
    dir="${STATE}/${node}"
    sock="${dir}/myco.sock"
    out=$(cd "$dir" && MYCO_UDS_PATH="$sock" MYCO_STATE_DIR="$dir" timeout "${STATUS_TIMEOUT_SEC}" "${BIN}" status 2>&1 || true)
    known=$(awk '/services_known/{print $2; exit}' <<<"$out")
    if [ -z "$known" ] || [ "$known" -lt "$TOTAL_SERVICES" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" -eq 1 ]; then
    converged_ts=$(date +%s)
    echo "Converged after $i checks."
    break
  fi
  sleep 2
done

if [ "$all_ok" -ne 1 ]; then
  echo "Convergence not reached; dumping status for each node:"
  for node in "${NODE_NAMES[@]}"; do
    dir="${STATE}/${node}"
    sock="${dir}/myco.sock"
    echo "--- ${node} ---"
    (cd "$dir" && MYCO_UDS_PATH="$sock" MYCO_STATE_DIR="$dir" timeout "${STATUS_TIMEOUT_SEC}" "${BIN}" status) || true
  done
  exit 1
fi

if [ "$inject_start_ts" -gt 0 ] && [ "$converged_ts" -gt 0 ]; then
  echo "==> Converged in $((converged_ts - inject_start_ts))s after job injection started"
fi
if [ "$inject_end_ts" -gt 0 ] && [ "$converged_ts" -gt 0 ]; then
  echo "==> Converged in $((converged_ts - inject_end_ts))s after job injection finished"
fi

echo "==> Metrics:"
for node in "${NODE_NAMES[@]}"; do
  dir="${STATE}/${node}"
  sock="${dir}/myco.sock"
  echo "--- ${node} ---"
  (cd "$dir" && MYCO_UDS_PATH="$sock" MYCO_STATE_DIR="$dir" timeout "${STATUS_TIMEOUT_SEC}" "${BIN}" status) || true
done

echo "Cluster smoke completed."
`
	smokeRunner := runner.
		WithEnvVariable("ZIG_LOCAL_CACHE_DIR", "/src/zig-cache").
		WithEnvVariable("ZIG_GLOBAL_CACHE_DIR", "/src/zig-cache")
	if value := os.Getenv("MYCO_SMOKE_OPTIMIZE"); value != "" {
		smokeRunner = smokeRunner.WithEnvVariable("MYCO_SMOKE_OPTIMIZE", value)
	}
	smokeRunner = smokeRunner.WithEnvVariable("MYCO_SMOKE_NODES", strconv.Itoa(nodes))
	smokeRunner = smokeRunner.WithEnvVariable("MYCO_SMOKE_JOBS_PER_NODE", strconv.Itoa(jobs))
	smokeRunner = smokeRunner.WithEnvVariable("MYCO_SMOKE_MAX_WAIT_SEC", maxWait)
	_, err := smokeRunner.
		WithExec([]string{"timeout", "900", "bash", "-c", clusterScript}).
		Sync(ctx)

	return err
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
