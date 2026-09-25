#!/usr/bin/env bash
# Tear down the Grove + Kueue coexistence demo (sample CRs + optional operators).
#
# Usage:
#   ./scripts/uninstall.sh
#   FORCE=1 ./scripts/uninstall.sh
#   KEEP_OPERATORS=0 ./scripts/uninstall.sh   # also remove Karta/Grove/Kueue
#
# Default KEEP_OPERATORS=1 — safe when using the shared gallery operators.
set -euo pipefail

NS_DEMO="${NS_DEMO:-demo}"
RELEASE_DEMO="${RELEASE_DEMO:-demo}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_GROVE="${NS_GROVE:-grove-system}"
NS_KUEUE="${NS_KUEUE:-kueue-system}"
RELEASE_KARTA="${RELEASE_KARTA:-karta}"
RELEASE_GROVE="${RELEASE_GROVE:-grove-operator}"
RELEASE_KUEUE="${RELEASE_KUEUE:-kueue}"
FORCE="${FORCE:-0}"
KEEP_OPERATORS="${KEEP_OPERATORS:-1}"

if command -v oc >/dev/null 2>&1; then
  OC="${OC:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  OC="${OC:-kubectl}"
else
  echo "Need oc or kubectl on PATH" >&2
  exit 1
fi

section() { echo ""; echo "============================================================"; echo "==> $*"; echo "============================================================"; }
info() { echo "    [info] $*"; }
ok()   { echo "    [ok]   $*"; }
warn() { echo "    [warn] $*"; }

helm_uninstall() {
  local release="$1" ns="$2"
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
  local kind="$1" name="$2"
  if "$OC" get "$kind" "$name" >/dev/null 2>&1; then
    info "Deleting $kind/$name"
    "$OC" delete "$kind" "$name" --ignore-not-found=true || warn "Could not delete $kind/$name"
  else
    info "$kind/$name not found (skip)"
  fi
}

section "Uninstall karta-grove-kueue"
info "CLI: $OC"
info "Demo release $RELEASE_DEMO in $NS_DEMO"
if [[ "${KEEP_OPERATORS}" == "1" ]]; then
  info "Operators: keep (KEEP_OPERATORS=1)"
else
  info "Operators: remove Karta/Grove/Kueue"
fi

if [[ "${FORCE}" != "1" ]]; then
  echo ""
  read -r -p "    Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    warn "Aborted (no changes)."
    exit 0
  fi
fi

section "1. Demo Helm release"
if "$OC" get ns "$NS_DEMO" >/dev/null 2>&1; then
  "$OC" delete job kueue-demo-job openshift-batch-job -n "$NS_DEMO" --ignore-not-found=true || true
fi
helm_uninstall "$RELEASE_DEMO" "$NS_DEMO"

section "2. Cluster-scoped demo CRs"
delete_cluster_obj clusterqueue demo-cluster-queue
delete_cluster_obj resourceflavor grove-kueue-flavor
delete_cluster_obj karta grove-kueue-podcliqueset-v1alpha1
delete_cluster_obj karta grove-kueue-batch-job-v1

section "3. Demo namespace"
delete_ns "$NS_DEMO"

section "4. Operators"
if [[ "${KEEP_OPERATORS}" == "1" ]]; then
  warn "Skipping operator uninstall (KEEP_OPERATORS=1)"
else
  helm_uninstall "$RELEASE_KUEUE" "$NS_KUEUE"
  helm_uninstall "$RELEASE_GROVE" "$NS_GROVE"
  helm_uninstall "$RELEASE_KARTA" "$NS_KARTA"
  delete_ns "$NS_KUEUE"
  delete_ns "$NS_GROVE"
  delete_ns "$NS_KARTA"
fi

echo ""
ok "Uninstall finished."
info "Re-install: ./scripts/install-operators.sh && helm upgrade --install demo .. -n demo --create-namespace"
