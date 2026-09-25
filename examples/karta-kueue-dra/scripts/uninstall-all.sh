#!/usr/bin/env bash
# Tear down the Karta + Kueue + DRA showcase: demo chart, demo namespace, and operators.
#
# Removes:
#   1. Helm release dra-demo (+ Jobs / LocalQueue / claim template in dra-demo)
#   2. Namespace dra-demo
#   3. Leftover cluster-scoped demo CRs (ClusterQueue, ResourceFlavor, DeviceClass, Karta)
#   4. Helm releases kueue + karta
#   5. Namespaces kueue-system + karta-system
#
# Usage:
#   ./scripts/uninstall-all.sh
#   FORCE=1 ./scripts/uninstall-all.sh          # no confirmation prompt
#   KEEP_OPERATORS=1 ./scripts/uninstall-all.sh # demo only; leave Karta/Kueue
#
# Does not remove a GPU DRA driver (this demo never installed one).
set -euo pipefail

NS_DEMO="${NS_DEMO:-dra-demo}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_KUEUE="${NS_KUEUE:-kueue-system}"
RELEASE_DEMO="${RELEASE_DEMO:-dra-demo}"
RELEASE_KARTA="${RELEASE_KARTA:-karta}"
RELEASE_KUEUE="${RELEASE_KUEUE:-kueue}"
FORCE="${FORCE:-0}"
KEEP_OPERATORS="${KEEP_OPERATORS:-0}"

if command -v oc >/dev/null 2>&1; then
  OC="${OC:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  OC="${OC:-kubectl}"
else
  echo "Need oc or kubectl on PATH" >&2
  exit 1
fi

section() {
  echo ""
  echo "============================================================"
  echo "==> $*"
  echo "============================================================"
}

info() { echo "    [info] $*"; }
ok()   { echo "    [ok]   $*"; }
warn() { echo "    [warn] $*"; }

helm_uninstall() {
  local release="$1"
  local ns="$2"
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    info "helm uninstall $release -n $ns"
    helm uninstall "$release" -n "$ns" || warn "helm uninstall $release failed (continuing)"
    ok "Removed Helm release $release"
  else
    info "Helm release $release not found in $ns (skip)"
  fi
}

delete_ns() {
  local ns="$1"
  if "$OC" get ns "$ns" >/dev/null 2>&1; then
    info "Deleting namespace $ns ..."
    "$OC" delete ns "$ns" --wait=false
    ok "Namespace $ns delete requested"
  else
    info "Namespace $ns not found (skip)"
  fi
}

delete_cluster_obj() {
  local kind="$1"
  local name="$2"
  if "$OC" get "$kind" "$name" >/dev/null 2>&1; then
    info "Deleting $kind/$name"
    "$OC" delete "$kind" "$name" --ignore-not-found=true || warn "Could not delete $kind/$name"
  else
    info "$kind/$name not found (skip)"
  fi
}

section "Uninstall Karta + Kueue + DRA demo"
info "CLI: $OC"
info "Will remove:"
info "  - Helm release $RELEASE_DEMO in $NS_DEMO (+ namespace $NS_DEMO)"
info "  - Cluster-scoped demo CRs: ClusterQueue/ResourceFlavor/DeviceClass/Karta"
if [[ "${KEEP_OPERATORS}" == "1" ]]; then
  info "  - Operators: KEEP_OPERATORS=1 (leaving Karta/Kueue installed)"
else
  info "  - Helm releases $RELEASE_KUEUE + $RELEASE_KARTA"
  info "  - Namespaces $NS_KUEUE + $NS_KARTA"
fi

if [[ "${FORCE}" != "1" ]]; then
  echo ""
  read -r -p "    Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    warn "Aborted (no changes)."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
section "1. Demo Helm release + Jobs"
# ---------------------------------------------------------------------------
# Delete Jobs first so Workloads release cleanly before helm uninstall.
if "$OC" get ns "$NS_DEMO" >/dev/null 2>&1; then
  info "Deleting sample Jobs (ignore if already gone)..."
  "$OC" delete job dra-job-admit dra-job-queued -n "$NS_DEMO" --ignore-not-found=true || true
fi
helm_uninstall "$RELEASE_DEMO" "$NS_DEMO"

# ---------------------------------------------------------------------------
section "2. Cluster-scoped demo CRs (safety net if Helm left them)"
# ---------------------------------------------------------------------------
# Names match values.yaml defaults for this chart.
delete_cluster_obj clusterqueue dra-cluster-queue
delete_cluster_obj resourceflavor dra-gpu-flavor
delete_cluster_obj deviceclass gpu.example.com
delete_cluster_obj karta dra-batch-job-v1
# Legacy name from pre-prefix defaults (safe no-op if absent).
delete_cluster_obj karta batch-job-v1

# ---------------------------------------------------------------------------
section "3. Demo namespace $NS_DEMO"
# ---------------------------------------------------------------------------
delete_ns "$NS_DEMO"

# ---------------------------------------------------------------------------
section "4. Operators (Kueue + Karta)"
# ---------------------------------------------------------------------------
if [[ "${KEEP_OPERATORS}" == "1" ]]; then
  warn "Skipping operator uninstall (KEEP_OPERATORS=1)"
else
  helm_uninstall "$RELEASE_KUEUE" "$NS_KUEUE"
  helm_uninstall "$RELEASE_KARTA" "$NS_KARTA"
  delete_ns "$NS_KUEUE"
  delete_ns "$NS_KARTA"
fi

# ---------------------------------------------------------------------------
section "5. Verify"
# ---------------------------------------------------------------------------
info "Helm releases (all namespaces) matching demo/operators:"
helm list -A 2>/dev/null | grep -E "NAME|${RELEASE_DEMO}|${RELEASE_KARTA}|${RELEASE_KUEUE}" || info "(none matching)"

info "Namespaces:"
for ns in "$NS_DEMO" "$NS_KARTA" "$NS_KUEUE"; do
  if "$OC" get ns "$ns" >/dev/null 2>&1; then
    phase="$("$OC" get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    warn "Namespace $ns still present (phase=$phase) — OpenShift may finish deletion shortly"
  else
    ok "Namespace $ns gone"
  fi
done

info "Cluster-scoped leftovers:"
for pair in "clusterqueue/dra-cluster-queue" "resourceflavor/dra-gpu-flavor" "deviceclass/gpu.example.com" "karta/dra-batch-job-v1" "karta/batch-job-v1"; do
  kind="${pair%%/*}"
  name="${pair##*/}"
  if "$OC" get "$kind" "$name" >/dev/null 2>&1; then
    warn "Still present: $pair"
  else
    ok "Gone: $pair"
  fi
done

echo ""
ok "Uninstall finished."
info "Namespaces marked for deletion can take a minute to disappear."
info "Re-install later: ./scripts/install-operators.sh && helm upgrade --install dra-demo .. -n dra-demo --create-namespace"
info "Or: ./scripts/runthrough.sh"
