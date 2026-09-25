#!/usr/bin/env bash
# Install Karta + KubeRay operators (prerequisites for the compound-CRD showcase).
# Does NOT install KAI or Grove — those stay optional consumers of the Karta map.
set -euo pipefail

KARTA_VERSION="${KARTA_VERSION:-0.2.0}"
# Chart still published at run-ai GHCR; dsx-ai-factory/workload-map OCI path is not published yet.
KARTA_CHART="${KARTA_CHART:-oci://ghcr.io/run-ai/karta/karta}"
KARTA_NAMESPACE="${KARTA_NAMESPACE:-karta-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

KUBERAY_VERSION="${KUBERAY_VERSION:-1.3.2}"
KUBERAY_CHART="${KUBERAY_CHART:-kuberay/kuberay-operator}"
KUBERAY_NAMESPACE="${KUBERAY_NAMESPACE:-ray-system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "------------------------------------------------------------"
echo "==> Installing operators: Karta + KubeRay (no Grove / no KAI)"
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

echo "==> KubeRay operator ${KUBERAY_VERSION}"
# Prefer an already-running KubeRay (OperatorHub / another chart / shared cluster).
# FORCE_KUBERAY_INSTALL=1 opts into installing our own release anyway.
kuberay_already_running() {
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'
}

if [[ "${FORCE_KUBERAY_INSTALL:-0}" != "1" ]] && kuberay_already_running; then
  echo "    KubeRay operator already Running — reusing it (skip helm install)."
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" { print "      " $1 "/" $2 "  " $3 }'
else
  echo "    helm repo kuberay + chart ${KUBERAY_CHART} ${KUBERAY_VERSION} → ${KUBERAY_NAMESPACE}"
  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
  helm repo update kuberay >/dev/null
  # Chart defaults are OpenShift-friendly (runAsNonRoot, no fixed UID).
  helm upgrade --install kuberay-operator "${KUBERAY_CHART}" \
    --version "${KUBERAY_VERSION}" \
    --namespace "${KUBERAY_NAMESPACE}" \
    --create-namespace \
    --wait --timeout "${HELM_TIMEOUT}" \
    || {
      echo "==> KubeRay helm failed." >&2
      echo "    If KubeRay is provided elsewhere (OperatorHub / another ns), confirm:" >&2
      echo "      kubectl get deploy -A | grep -iE 'kuberay|ray-operator'" >&2
      echo "      kubectl get crd | grep ray.io" >&2
      echo "    Then re-run without FORCE_KUBERAY_INSTALL (reuse is default)." >&2
      exit 1
    }
fi

echo ""
echo "------------------------------------------------------------"
echo "==> Operators ready. Install the example chart:"
echo "    helm upgrade --install ray-demo ${SCRIPT_DIR}/.. -n ray-demo --create-namespace"
echo "------------------------------------------------------------"
