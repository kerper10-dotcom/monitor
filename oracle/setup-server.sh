#!/bin/bash
# Run once on fresh Ubuntu VM (Oracle): bash setup-server.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> System packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  python3 python3-pip python3-venv git rsync curl \
  libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 \
  libasound2t64 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  2>/dev/null || sudo apt-get install -y -qq \
  python3 python3-pip python3-venv git rsync curl \
  libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libgbm1 \
  libasound2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2

mkdir -p /home/ubuntu/bots
echo "==> Server ready. Deploy bots from Mac with: ./oracle/deploy-from-mac.sh <VM_IP>"