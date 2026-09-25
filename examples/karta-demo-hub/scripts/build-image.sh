#!/usr/bin/env bash
# Build the gallery image. Context must be the run-ai-karta repo root
# (Containerfile COPYs sibling examples/*/presentation and runthroughs).
#
# Usage (from anywhere):
#   ./scripts/build-image.sh
#   IMAGE=quay.io/example/karta-demo-hub:0.1.0 ./scripts/build-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HUB_DIR}/../.." && pwd)"

IMAGE="${IMAGE:-karta-demo-hub:0.1.0}"
# OpenShift nodes are almost always amd64. Override for local-only runs:
#   PLATFORM=linux/arm64 ./scripts/build-image.sh
PLATFORM="${PLATFORM:-linux/amd64}"
case "${PLATFORM}" in
  linux/*) ;;
  *) PLATFORM="linux/${PLATFORM}" ;;
esac

echo "==> Building ${IMAGE}"
echo "    context:  ${REPO_ROOT}"
echo "    file:     examples/karta-demo-hub/Containerfile"
echo "    platform: ${PLATFORM}"
echo ""

cd "${REPO_ROOT}"
podman build \
  --platform "${PLATFORM}" \
  -f examples/karta-demo-hub/Containerfile \
  -t "${IMAGE}" \
  .
