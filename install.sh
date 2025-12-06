#!/bin/bash
set -e

# 1. Detect Architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ZIG_TARGET="x86_64-linux-musl"
elif [ "$ARCH" = "aarch64" ]; then
    ZIG_TARGET="aarch64-linux-musl"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "[*] Installing Myco for $ZIG_TARGET..."

# 2. Check for Nix (Prerequisite)
if ! command -v nix &> /dev/null; then
    echo "[!] Nix is not installed. Installing the Determinate Systems Nix Installer..."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# 3. Build/Fetch Binary
# (In a real release, we would download from GitHub Releases. 
# For now, we assume this script runs inside the repo or we build from source)
if [ -f "build.zig" ]; then
    echo "[*] Building from source..."
    # Ensure Zig is available (via Nix shell if needed, or assume user has it)
    # For the Skeleton, we'll assume the user is running this from the repo
    nix run nixpkgs#zig -- build -Dtarget=$ZIG_TARGET -Doptimize=ReleaseSmall
    
    echo "[*] Installing to /usr/local/bin..."
    sudo cp zig-out/bin/myco /usr/local/bin/
    sudo chmod +x /usr/local/bin/myco
else
    echo "[!] Run this script from the source repository."
    exit 1
fi

# 4. Init Systemd Service
echo "[*] Setting up Systemd..."
# We create a simple unit that runs 'myco up' on boot
cat <<EOF | sudo tee /etc/systemd/system/myco.service
[Unit]
Description=Myco Sovereign Orchestrator
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/myco up
Restart=always
RestartSec=5
# Inherit env vars from a config file if needed
EnvironmentFile=-/etc/myco/env

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable myco

echo "[+] Installation Complete!"
echo "    Run 'sudo myco init' to configure your first service."
