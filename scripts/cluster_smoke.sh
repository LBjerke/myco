#!/usr/bin/env bash
set -euo pipefail

# Build a small three-node cluster in Docker, wire peers, and deploy a test service.

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
zig build -Doptimize=ReleaseSmall -Dtarget="${TARGET}"

echo "==> Building Podman image (bundles host-built binary)..."
podman build -f scripts/myco.dockerfile -t myco:latest .

echo "==> Starting cluster..."
podman compose -f scripts/docker-compose.yaml up -d

trap 'podman compose -f scripts/docker-compose.yaml down' EXIT

echo "==> Fetching pubkeys..."
PUB_A=$(podman exec myco-node-a sh -c 'MYCO_STATE_DIR=/var/lib/myco myco pubkey')
PUB_B=$(podman exec myco-node-b sh -c 'MYCO_STATE_DIR=/var/lib/myco myco pubkey')
PUB_C=$(podman exec myco-node-c sh -c 'MYCO_STATE_DIR=/var/lib/myco myco pubkey')

PREFIX="${MYCO_NET_PREFIX:-10.99.0}"
echo "==> Wiring peers..."
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-a myco peer add "${PUB_B}" "${PREFIX}.3:7778"
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-a myco peer add "${PUB_C}" "${PREFIX}.4:7779"
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-b myco peer add "${PUB_A}" "${PREFIX}.2:7777"
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-b myco peer add "${PUB_C}" "${PREFIX}.4:7779"
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-c myco peer add "${PUB_A}" "${PREFIX}.2:7777"
podman exec -e MYCO_STATE_DIR=/var/lib/myco myco-node-c myco peer add "${PUB_B}" "${PREFIX}.3:7778"

echo "==> Deploying sample service to all nodes..."
cat > /tmp/myco-svc.json <<'EOF'
{
  "id": 1,
  "name": "hello",
  "flake_uri": "github:example/hello",
  "exec_name": "run"
}
EOF
for node in myco-node-a myco-node-b myco-node-c; do
  podman cp /tmp/myco-svc.json ${node}:/var/lib/myco/myco.json
  podman exec -w /var/lib/myco -e MYCO_STATE_DIR=/var/lib/myco "${node}" myco deploy || true
done

echo "==> Metrics:"
for node in myco-node-a myco-node-b myco-node-c; do
  echo "--- $node ---"
  podman exec -e MYCO_UDS_PATH=/tmp/myco.sock "$node" myco status || true
done

echo "Cluster smoke completed. Containers left running; Ctrl+C will stop them."
wait
