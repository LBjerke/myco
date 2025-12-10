#!/bin/bash
set -e

# Build
echo "[*] Building..."
zig build

# Cleanup previous test
rm -rf test_env
mkdir -p test_env/node_a/services
mkdir -p test_env/node_b/services

BIN=$(pwd)/zig-out/bin/myco

echo "[*] Initializing Node A (Leader)..."
cd test_env/node_a
export MYCO_STATE_DIR=$(pwd)/state
export MYCO_PORT=7777
mkdir -p $MYCO_STATE_DIR

# Create Redis config manually to skip interactive prompt
echo '{"name":"redis","package":"nixpkgs#redis","port":6379}' > services/redis.json

# Add Node B as peer (pointing to port 7778)
sudo -E $BIN peer add node-b 127.0.0.1:7778

echo "[*] Starting Node A in background..."
sudo -E $BIN up > node_a.log 2>&1 &
PID_A=$!

# Wait for A to start
sleep 2

echo "[*] Initializing Node B (Follower)..."
cd ../node_b
export MYCO_STATE_DIR=$(pwd)/state
export MYCO_PORT=7778
mkdir -p $MYCO_STATE_DIR

echo "[*] Starting Node B..."
echo "    (Watch for 'Synced redis' in the output below)"
echo "---------------------------------------------------"

# Run Node B in foreground for 10 seconds then kill everything
timeout 10s sudo -E $BIN up || true

echo "---------------------------------------------------"
echo "[*] Test Finished."

# Verify Transfer
if [ -f "services/redis.json" ]; then
    echo "SUCCESS: Node B received redis.json!"
else
    echo "FAILURE: Node B did not receive config."
fi

# Cleanup
sudo kill $PID_A
