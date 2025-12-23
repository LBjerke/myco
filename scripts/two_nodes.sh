#!/usr/bin/env bash
set -euo pipefail

# Local multi-node replication smoke test (no containers).
# Defaults: 5 nodes, 10 services/node, ports starting at 7777.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT_BASE=${PORT_BASE:-7777}
API_PORT_BASE=${API_PORT_BASE:-21777}
PACKET_KEY=${PACKET_KEY:-ci-packet-key}
PACKET_EPOCH=${PACKET_EPOCH:-1}
TRANSPORT_PSK=${TRANSPORT_PSK:-ci-transport-psk}
NODE_COUNT=${NODES:-5}
SERVICES_PER_NODE=${SERVICES_PER_NODE:-10}
QUIET_STATUS=${QUIET_STATUS:-0}
NODE_NAMES=()
PORTS=()
API_PORTS=()
STATES=()
UDS=()

# Enforce encrypted transport/packets during CI smoke tests.
unset MYCO_PACKET_PLAINTEXT MYCO_PACKET_ALLOW_PLAINTEXT MYCO_TRANSPORT_PLAINTEXT MYCO_TRANSPORT_ALLOW_PLAINTEXT

uppercase() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

for idx in $(seq 0 $((NODE_COUNT - 1))); do
  NODE_NAMES[$idx]="n$((idx + 1))"
  PORTS[$idx]=$((PORT_BASE + idx))
  API_PORTS[$idx]=$((API_PORT_BASE + idx))
  STATES[$idx]="/tmp/myco-node-${NODE_NAMES[$idx]}"
  UDS[$idx]="${STATES[$idx]}/myco.sock"
done

cleanup() {
  pkill -f "myco daemon" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
sleep 0.5

rm -rf "${STATES[@]}"
mkdir -p "${STATES[@]}"

echo "==> Building myco (ReleaseFast)..."
zig build -Doptimize=ReleaseFast

echo "==> Starting ${NODE_COUNT} nodes..."
for idx in "${!NODE_NAMES[@]}"; do
  name="${NODE_NAMES[$idx]}"
  port="${PORTS[$idx]}"
  api_port="${API_PORTS[$idx]}"
  state="${STATES[$idx]}"
  uds="${UDS[$idx]}"
  upper_name=$(uppercase "$name")
  echo "   - node ${upper_name} on ${port} (state ${state})"
  node_id=$((1001 + idx))
  MYCO_STATE_DIR="$state" \
  MYCO_PORT="$port" \
  MYCO_NODE_ID="$node_id" \
  MYCO_PACKET_KEY="$PACKET_KEY" \
  MYCO_PACKET_EPOCH="$PACKET_EPOCH" \
  MYCO_TRANSPORT_PSK="$TRANSPORT_PSK" \
  MYCO_SMOKE_SKIP_EXEC=1 \
  MYCO_UDS_PATH="$uds" \
  MYCO_API_TCP_PORT="$api_port" \
  ./zig-out/bin/myco daemon >"/tmp/myco-${name}.log" 2>&1 &
  sleep 0.5
done

PUBS=()
for idx in "${!NODE_NAMES[@]}"; do
  PUBS[$idx]=$(MYCO_STATE_DIR="${STATES[$idx]}" ./zig-out/bin/myco pubkey)
done

wait_for_api() {
  local state="$1"
  local uds="$2"
  local api_port="$3"
  local tries=0
  while (( tries < 40 )); do
    if MYCO_STATE_DIR="$state" MYCO_UDS_PATH="$uds" MYCO_API_TCP_PORT="$api_port" ./zig-out/bin/myco status >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    tries=$((tries + 1))
  done
  return 1
}

echo "==> Waiting for APIs..."
for idx in "${!NODE_NAMES[@]}"; do
  state="${STATES[$idx]}"
  uds="${UDS[$idx]}"
  api_port="${API_PORTS[$idx]}"
  wait_for_api "$state" "$uds" "$api_port" || { echo "Node ${NODE_NAMES[$idx]} API not ready"; exit 1; }
done

echo "==> Wiring peers (full mesh)..."
for i in "${!NODE_NAMES[@]}"; do
  for j in "${!NODE_NAMES[@]}"; do
    [ "$i" -eq "$j" ] && continue
    MYCO_STATE_DIR="${STATES[$i]}" ./zig-out/bin/myco peer add "${PUBS[$j]}" "127.0.0.1:${PORTS[$j]}"
  done
done

echo "==> Deploying ${SERVICES_PER_NODE} services to each node..."
for idx in "${!NODE_NAMES[@]}"; do
  state="${STATES[$idx]}"
  uds="${UDS[$idx]}"
  api_port="${API_PORTS[$idx]}"
  name="${NODE_NAMES[$idx]}"
  for i in $(seq 1 $SERVICES_PER_NODE); do
cat > "$state/myco.json" <<EOF
{
  "name": "svc-${name}-${i}",
  "flake_uri": "github:example/${name}/svc-${i}",
  "exec_name": "run"
}
EOF
    (cd "$state" && MYCO_STATE_DIR="$state" MYCO_UDS_PATH="$uds" MYCO_API_TCP_PORT="$api_port" "$ROOT/zig-out/bin/myco" deploy >/dev/null 2>&1)
  done
done

target=$((NODE_COUNT * SERVICES_PER_NODE))
start=$(date +%s)
echo "Waiting for all nodes to reach $target services_known..."
while :; do
  all_good=true
  ready=0
  for idx in "${!NODE_NAMES[@]}"; do
    state="${STATES[$idx]}"
    uds="${UDS[$idx]}"
    api_port="${API_PORTS[$idx]}"
    out=$(MYCO_UDS_PATH="$uds" MYCO_API_TCP_PORT="$api_port" MYCO_STATE_DIR="$state" ./zig-out/bin/myco status || true)
    known=$(echo "$out" | awk '/services_known/{print $2}' | head -n1)
    upper=$(uppercase "${NODE_NAMES[$idx]}")
    if [ "$known" = "$target" ]; then
      ready=$((ready + 1))
    else
      all_good=false
    fi
    if [ "$QUIET_STATUS" -eq 0 ]; then
      echo "--- node ${upper} ---"; echo "$out"
    fi
  done
  if [ "$QUIET_STATUS" -ne 0 ]; then
    elapsed=$(( $(date +%s) - start ))
    echo "progress: ${ready}/${NODE_COUNT} nodes at ${target} services (elapsed ${elapsed}s)"
  fi
  if [ "$all_good" = true ]; then
    elapsed=$(( $(date +%s) - start ))
    echo "✅ All nodes converged to $target services in ${elapsed}s"
    break
  fi
  if [ $(( $(date +%s) - start )) -ge 180 ]; then
    echo "⚠️ Timed out waiting for convergence"
    exit 1
  fi
  sleep 2
done
