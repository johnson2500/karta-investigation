#!/usr/bin/env bash
# Tear down the Karta + Kueue + DRA demo (wrapper around uninstall-all.sh).
#
# Default KEEP_OPERATORS=1 — removes the demo only (safe with the gallery hub).
# Use KEEP_OPERATORS=0 to also remove Karta/Kueue (same as uninstall-all.sh default).
#
# Usage:
#   ./scripts/uninstall.sh
#   FORCE=1 ./scripts/uninstall.sh
#   KEEP_OPERATORS=0 ./scripts/uninstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KEEP_OPERATORS="${KEEP_OPERATORS:-1}"
export FORCE="${FORCE:-0}"
exec "${SCRIPT_DIR}/uninstall-all.sh"
