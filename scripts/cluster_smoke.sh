#!/usr/bin/env bash
set -euo pipefail

# Build a small five-node cluster in Podman, wire peers, and deploy 50 test services via the myco CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-./zig-cache}"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-./zig-cache}"
export ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR

if ! podman info >/dev/null 2>&1; then
  echo "Podman is not running or configured. On macOS try: podman machine init --now"
  exit 1
fi

TARGET="${ZIG_TARGET:-x86_64-linux-musl}"
echo "==> Building myco ReleaseSmall binary on host for ${TARGET}..."
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR}" ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR}" zig build -Doptimize=ReleaseSmall -Dtarget="${TARGET}"

if [ ! -f "$ROOT/zig-out/bin/myco" ]; then
  echo "Error: zig-out/bin/myco not found; build may have failed."
  exit 1
fi

echo "==> Building Podman image (bundles host-built binary)..."
podman build -f scripts/myco.dockerfile -t myco:latest .

echo "==> Starting cluster..."
# Always start from a clean slate so stale state doesn't break gossip.
podman compose -f scripts/docker-compose.yaml down --remove-orphans >/dev/null 2>&1 || true
# Use the prebuilt image; avoid per-service rebuilds.
podman compose -f scripts/docker-compose.yaml up -d --no-build

NODES=(myco-node-a myco-node-b myco-node-c myco-node-d myco-node-e)
PORTS=(7777 7778 7779 7780 7781)

echo "==> Fetching pubkeys..."
PUBS=()
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"
  PUBS[$i]="$(podman exec "$node" sh -c 'MYCO_STATE_DIR=/var/lib/myco myco pubkey')"
done

PREFIX="${MYCO_NET_PREFIX:-10.99.0}"
echo "==> Wiring peers (full mesh)..."
for i in "${!NODES[@]}"; do
  for j in "${!NODES[@]}"; do
    if [ "$i" -eq "$j" ]; then continue; fi
    src="${NODES[$i]}"
    dst="${NODES[$j]}"
    port="${PORTS[$j]}"
    ip_octet=$((2 + j))
    podman exec -e MYCO_STATE_DIR=/var/lib/myco "$src" myco peer add "${PUBS[$j]}" "${PREFIX}.$ip_octet:${port}"
  done
done

echo "==> Deploying 10 services via myco deploy on each node..."
tmpdir="$(mktemp -d)"
cleanup_all() {
  rm -rf "$tmpdir"
  podman compose -f scripts/docker-compose.yaml down
}
trap cleanup_all EXIT

svc_id=1
for idx in "${!NODES[@]}"; do
  node="${NODES[$idx]}"
  echo "==> Waiting for ${node} API..."
  for _ in {1..30}; do
    if podman exec -e MYCO_UDS_PATH=/tmp/myco.sock "$node" sh -c 'myco status >/dev/null 2>&1'; then
      break
    fi
    sleep 1
  done

  for i in $(seq 1 10); do
    cat > "$tmpdir/myco.json" <<EOF
{
  "name": "svc-${node}-$i",
  "flake_uri": "github:example/${node}/svc-$i",
  "exec_name": "run"
}
EOF
    podman cp "$tmpdir/myco.json" "${node}:/var/lib/myco/myco.json"
    podman exec -w /var/lib/myco -e MYCO_STATE_DIR=/var/lib/myco -e MYCO_UDS_PATH=/tmp/myco.sock "$node" myco deploy || true
    svc_id=$((svc_id + 1))
  done
done

echo "==> Metrics:"
target_services=$(( ${#NODES[@]} * 10 ))
start_ts=$(date +%s)
echo "Waiting for convergence to ${target_services} services per node..."
while :; do
  all_good=true
  for node in "${NODES[@]}"; do
    status_out=$(podman exec -e MYCO_STATE_DIR=/var/lib/myco -e MYCO_UDS_PATH=/tmp/myco.sock "$node" sh -c 'myco status || cat /var/lib/myco/myco.json' 2>&1 || true)
    echo "--- $node ---"
    if [ -n "$status_out" ]; then
      echo "$status_out"
      known=$(echo "$status_out" | awk '/services_known/{print $2}' | head -n1)
      if [ -z "$known" ] || [ "$known" -lt "$target_services" ]; then
        all_good=false
      fi
    else
      echo "(no output from status)"
      all_good=false
    fi
  done
  end_ts=$(date +%s)
  elapsed=$(( end_ts - start_ts ))
  if [ "$all_good" = true ]; then
    echo "✅ Converged in ${elapsed}s (services_known >= ${target_services} on all nodes)"
    break
  fi
  if [ "$elapsed" -ge 600 ]; then
    echo "⚠️ Timed out after ${elapsed}s without full convergence"
    break
  fi
  sleep 5
done

echo "Cluster smoke completed. Containers left running; Ctrl+C will stop them."
wait
