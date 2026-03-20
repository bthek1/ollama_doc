#!/usr/bin/env bash
# Phase 6 setup: Install NVIDIA Container Toolkit and stop bare-metal Ollama
set -euo pipefail

echo "=== Step 1: Add NVIDIA Container Toolkit repo ==="
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

echo "=== Step 2: Install nvidia-container-toolkit ==="
sudo apt-get update -qq
sudo apt-get install -y nvidia-container-toolkit

echo "=== Step 3: Configure Docker to use NVIDIA runtime ==="
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

echo "=== Step 4: Stop and disable bare-metal Ollama service ==="
sudo systemctl stop ollama
sudo systemctl disable ollama

echo "=== Step 5: Verify port 11434 is free ==="
ss -tlnp | grep 11434 && echo "WARNING: port 11434 still in use" || echo "Port 11434 is free"

echo ""
echo "=== Phase 6 complete! Now run: cd ~/ollama_doc && docker compose up -d ==="
