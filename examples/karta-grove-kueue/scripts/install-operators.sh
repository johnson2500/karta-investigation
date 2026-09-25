#!/usr/bin/env bash
# Install Karta, Grove, and Kueue operators (prerequisites for the example chart).
# Override versions via env vars before running.
set -euo pipefail

KARTA_VERSION="${KARTA_VERSION:-0.2.0}"
# Chart still published at run-ai GHCR; dsx-ai-factory/workload-map OCI path is not published yet.
KARTA_CHART="${KARTA_CHART:-oci://ghcr.io/run-ai/karta/karta}"
KARTA_NAMESPACE="${KARTA_NAMESPACE:-karta-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

GROVE_VERSION="${GROVE_VERSION:-v0.1.0-alpha.10-rc1}"
GROVE_CHART="${GROVE_CHART:-oci://ghcr.io/ai-dynamo/grove/grove-charts}"
GROVE_NAMESPACE="${GROVE_NAMESPACE:-grove-system}"

KUEUE_VERSION="${KUEUE_VERSION:-0.19.5}"
KUEUE_CHART="${KUEUE_CHART:-oci://registry.k8s.io/kueue/charts/kueue}"
KUEUE_NAMESPACE="${KUEUE_NAMESPACE:-kueue-system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROVE_VALUES="${SCRIPT_DIR}/grove-values.yaml"

echo ""
echo "------------------------------------------------------------"
echo "==> Installing operators: Karta + Grove + Kueue"
echo "    (OpenShift SCC-friendly Karta; Grove may be reused)"
echo "------------------------------------------------------------"
echo ""

echo "==> Karta ${KARTA_VERSION} (OpenShift-friendly: no fixed runAsUser)"
# Chart defaults pin runAsUser 65532, which fails OpenShift restricted-v2 SCC.
echo "    helm into ${KARTA_NAMESPACE} (--wait --timeout ${HELM_TIMEOUT}); if stuck after Pulled: oc get events -n ${KARTA_NAMESPACE}"
helm upgrade --install karta "${KARTA_CHART}" \
  --version "${KARTA_VERSION}" \
  --namespace "${KARTA_NAMESPACE}" \
  --create-namespace \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi \
  --wait --timeout "${HELM_TIMEOUT}" \
  || {
    echo "==> Karta helm failed/timed out. Check: oc get events -n ${KARTA_NAMESPACE} | grep FailedCreate" >&2
    echo "    Stuck release: helm uninstall karta -n ${KARTA_NAMESPACE}" >&2
    exit 1
  }

echo "==> Grove ${GROVE_VERSION} (default-scheduler only)"
# Prefer an already-running Grove operator (common on Dynamo / NVIDIA stacks).
# A second helm release fights CRD SSA + ClusterRole ownership
# (e.g. meta.helm.sh/release-name=dynamo in dynamo-platform).
# FORCE_GROVE_INSTALL=1 opts into installing our own release anyway.
grove_already_running() {
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'
}

if [[ "${FORCE_GROVE_INSTALL:-0}" != "1" ]] && grove_already_running; then
  echo "    Grove operator already Running — reusing it (skip helm install)."
  kubectl get deploy -A --no-headers 2>/dev/null | awk '$2 == "grove-operator" { print "      " $1 "/" $2 "  " $3 }'
  echo "    Demo PodCliqueSet pods still use schedulerName=default-scheduler (see chart values/templates)."
elif helm status grove-operator -n "${GROVE_NAMESPACE}" >/dev/null 2>&1; then
  echo "    Upgrading existing grove-operator release in ${GROVE_NAMESPACE}..."
  helm upgrade --install grove-operator "${GROVE_CHART}" \
    --version "${GROVE_VERSION}" \
    --namespace "${GROVE_NAMESPACE}" \
    --create-namespace \
    -f "${GROVE_VALUES}" \
    --wait --timeout "${HELM_TIMEOUT}"
else
  GROVE_HELM_EXTRA=()
  # Orphaned CRDs with no live operator: skip applying CRDs to avoid SSA .spec.versions conflicts.
  if kubectl get crd podcliquesets.grove.io >/dev/null 2>&1; then
    echo "    Grove CRDs present without our release; installing with --skip-crds"
    GROVE_HELM_EXTRA+=(--skip-crds)
  fi
  if [[ "${SKIP_GROVE_CRDS:-0}" == "1" ]]; then
    GROVE_HELM_EXTRA+=(--skip-crds)
  fi
  helm upgrade --install grove-operator "${GROVE_CHART}" \
    --version "${GROVE_VERSION}" \
    --namespace "${GROVE_NAMESPACE}" \
    --create-namespace \
    -f "${GROVE_VALUES}" \
    "${GROVE_HELM_EXTRA[@]}" \
    --wait --timeout "${HELM_TIMEOUT}" \
    || {
      echo "==> Grove helm failed." >&2
      echo "    If Grove is provided by another release (e.g. Dynamo), re-run without FORCE_GROVE_INSTALL" >&2
      echo "    and confirm: kubectl get deploy -A | grep grove-operator" >&2
      echo "    CRD SSA conflict: SKIP_GROVE_CRDS=1 ./scripts/install-operators.sh" >&2
      echo "    RBAC ownership conflict: reuse existing Grove (default) — do not delete Dynamo CRDs." >&2
      exit 1
    }
fi

echo "==> Kueue ${KUEUE_VERSION}"
helm upgrade --install kueue "${KUEUE_CHART}" \
  --version "${KUEUE_VERSION}" \
  --namespace "${KUEUE_NAMESPACE}" \
  --create-namespace \
  --wait --timeout "${HELM_TIMEOUT}"

echo ""
echo "------------------------------------------------------------"
echo "==> Operators ready. Install the example chart:"
echo "    helm upgrade --install demo ${SCRIPT_DIR}/.. -n demo --create-namespace"
echo "------------------------------------------------------------"
