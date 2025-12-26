package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"dagger.io/dagger"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Minute)
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
	errChan := make(chan error, 6)

	type checkTask struct {
		Name string
		Cmd  []string
	}

	tasks := []checkTask{
		{Name: "Format", Cmd: []string{"zig", "fmt", ".", "--check"}},
		{Name: "Build Check", Cmd: []string{"zig", "build"}},
		{Name: "Unit Tests", Cmd: []string{"bash", "-c", `
set -e
export ZIG_GLOBAL_CACHE_DIR=/src/zig-cache
export ZIG_LOCAL_CACHE_DIR=/src/zig-cache
plain_tests=(
  src/db/wal.zig
  src/net/handshake.zig
  src/p2p/peers.zig
  src/util/ux.zig
  src/engine/nix.zig
)
module_tests=(
  tests/sync_crdt.zig
  tests/cli.zig
  tests/engine.zig
)
for t in "${plain_tests[@]}"; do
  echo "==> zig test ${t}"
  timeout 300 zig test "${t}"
done
for t in "${module_tests[@]}"; do
  echo "==> zig test ${t} (with myco module)"
  timeout 300 zig test --dep myco -Mroot="${t}" -Mmyco=src/lib.zig
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
	fmt.Println("Building debug binary for smoke test (lighter)...")
	build := runner.
		WithEnvVariable("ZIG_LOCAL_CACHE_DIR", "/src/zig-cache").
		WithEnvVariable("ZIG_GLOBAL_CACHE_DIR", "/src/zig-cache").
		WithExec([]string{"zig", "build"})

	mycoBinary := build.File("/src/zig-out/bin/myco")
	smokeRunner := runner.
		WithFile("/src/zig-out/bin/myco", mycoBinary).
		WithExec([]string{"apk", "add", "--no-cache", "bash"})

	clusterScript := `
set -euo pipefail

BIN=/src/zig-out/bin/myco
STATE=/tmp/myco-smoke
rm -rf "${STATE}"
mkdir -p "${STATE}/a" "${STATE}/b" "${STATE}/c"

PORT_BASE=17777

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do
    kill "$p" >/dev/null 2>&1 || true
  done
}
dump_logs() {
  echo "==> Log tails (myco.log)"
  for node in a b c; do
    echo "--- ${node} ---"
    tail -n 200 "${STATE}/${node}/myco.log" || true
    echo ""
  done
}
on_exit() {
  status=$?
  trap - EXIT
  cleanup
  if [ "$status" -ne 0 ]; then
    dump_logs
  fi
  exit "$status"
}
trap on_exit EXIT

start_node() {
  name="$1"
  port="$2"
  dir="${STATE}/${name}"
  sock="${dir}/myco.sock"
  log="${dir}/myco.log"
  case "$name" in
    a) nid=1 ;;
    b) nid=2 ;;
    c) nid=3 ;;
  esac
  MYCO_STATE_DIR="$dir" MYCO_PORT="$port" MYCO_NODE_ID="$nid" MYCO_UDS_PATH="$sock" MYCO_TRANSPORT_ALLOW_PLAINTEXT=1 "${BIN}" daemon >"$log" 2>&1 &
  PIDS+=("$!")
}

echo "==> Starting nodes..."
start_node a $((PORT_BASE + 0))
start_node b $((PORT_BASE + 1))
start_node c $((PORT_BASE + 2))

sleep 2

echo "==> Fetching pubkeys..."
PUB_A=$(MYCO_STATE_DIR="${STATE}/a" MYCO_UDS_PATH="${STATE}/a/myco.sock" "${BIN}" pubkey)
PUB_B=$(MYCO_STATE_DIR="${STATE}/b" MYCO_UDS_PATH="${STATE}/b/myco.sock" "${BIN}" pubkey)
PUB_C=$(MYCO_STATE_DIR="${STATE}/c" MYCO_UDS_PATH="${STATE}/c/myco.sock" "${BIN}" pubkey)

echo "==> Wiring peers..."
MYCO_STATE_DIR="${STATE}/a" MYCO_UDS_PATH="${STATE}/a/myco.sock" "${BIN}" peer add "${PUB_B}" "127.0.0.1:$((PORT_BASE + 1))"
MYCO_STATE_DIR="${STATE}/a" MYCO_UDS_PATH="${STATE}/a/myco.sock" "${BIN}" peer add "${PUB_C}" "127.0.0.1:$((PORT_BASE + 2))"
MYCO_STATE_DIR="${STATE}/b" MYCO_UDS_PATH="${STATE}/b/myco.sock" "${BIN}" peer add "${PUB_A}" "127.0.0.1:$((PORT_BASE + 0))"
MYCO_STATE_DIR="${STATE}/b" MYCO_UDS_PATH="${STATE}/b/myco.sock" "${BIN}" peer add "${PUB_C}" "127.0.0.1:$((PORT_BASE + 2))"
MYCO_STATE_DIR="${STATE}/c" MYCO_UDS_PATH="${STATE}/c/myco.sock" "${BIN}" peer add "${PUB_A}" "127.0.0.1:$((PORT_BASE + 0))"
MYCO_STATE_DIR="${STATE}/c" MYCO_UDS_PATH="${STATE}/c/myco.sock" "${BIN}" peer add "${PUB_B}" "127.0.0.1:$((PORT_BASE + 1))"

echo "==> Preparing services..."
for node in a b c; do
  case "$node" in
    a) sid=1 ;;
    b) sid=2 ;;
    c) sid=3 ;;
  esac
  cat > "/tmp/myco-svc-${node}.json" <<JSON
{
  "id": ${sid},
  "name": "hello-${node}",
  "flake_uri": "github:example/hello-${node}",
  "exec_name": "run"
}
JSON
done

echo "==> Deploying each service to its node..."
for node in a b c; do
  dir="${STATE}/${node}"
  cp "/tmp/myco-svc-${node}.json" "${dir}/myco.json"
  (cd "${dir}" && MYCO_STATE_DIR="${dir}" MYCO_UDS_PATH="${dir}/myco.sock" "${BIN}" deploy) || true
done

echo "==> Waiting for convergence (expect 3 services per node)..."
EXPECTED=3
for i in $(seq 1 120); do
  all_ok=1
  for node in a b c; do
    dir="${STATE}/${node}"
    out=$(cd "${dir}" && MYCO_UDS_PATH="${dir}/myco.sock" MYCO_STATE_DIR="${dir}" "${BIN}" status 2>&1 || true)
    known=$(echo "$out" | awk '/services_known/{print $2; exit}')
    if [ -z "$known" ] || [ "$known" -lt "$EXPECTED" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" -eq 1 ]; then
    echo "Converged after $i checks."
    break
  fi
  sleep 2
done

if [ "$all_ok" -ne 1 ]; then
  echo "Convergence not reached; dumping status for each node:"
  for node in a b c; do
    echo "--- ${node} ---"
    dir="${STATE}/${node}"
    (cd "${dir}" && MYCO_UDS_PATH="${dir}/myco.sock" MYCO_STATE_DIR="${dir}" "${BIN}" status) || true
  done
  exit 1
fi

echo "==> Metrics:"
for node in a b c; do
  echo "--- ${node} ---"
  dir="${STATE}/${node}"
  (cd "${dir}" && MYCO_UDS_PATH="${dir}/myco.sock" MYCO_STATE_DIR="${dir}" "${BIN}" status) || true
done

echo "Cluster smoke completed."
`

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
