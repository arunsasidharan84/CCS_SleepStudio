#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

echo "Building AlmaLinux 8 builder image (GLIBC 2.28 compatible)..."
docker build -t ccs-builder-el8 -f scripts/Dockerfile.linux-el8 .

echo "Running build inside AlmaLinux 8 container..."
docker run --rm \
  -v "$repo_root:/workspace" \
  -w /workspace \
  ccs-builder-el8 \
  bash scripts/build_linux_in_container.sh

echo "Done! Linux installers are in dist/"
