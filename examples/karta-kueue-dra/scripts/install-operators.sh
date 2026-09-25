#!/usr/bin/env bash
# Install Karta and Kueue (with DRA deviceClassMappings) for the Kueue+DRA showcase.
# Does not install a GPU DRA driver — see README prerequisites.
set -euo pipefail

KARTA_VERSION="${KARTA_VERSION:-0.2.0}"
# Chart still published at run-ai GHCR; dsx-ai-factory/workload-map OCI path is not published yet.
KARTA_CHART="${KARTA_CHART:-oci://ghcr.io/run-ai/karta/karta}"
KARTA_NAMESPACE="${KARTA_NAMESPACE:-karta-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

KUEUE_VERSION="${KUEUE_VERSION:-0.19.5}"
KUEUE_CHART="${KUEUE_CHART:-oci://registry.k8s.io/kueue/charts/kueue}"
KUEUE_NAMESPACE="${KUEUE_NAMESPACE:-kueue-system}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUEUE_VALUES="${SCRIPT_DIR}/kueue-values.yaml"

echo ""
echo "------------------------------------------------------------"
echo "==> Installing operators: Karta + Kueue (DRA deviceClassMappings)"
echo "------------------------------------------------------------"
echo ""

echo "==> Karta ${KARTA_VERSION} (OpenShift-friendly: no fixed runAsUser)"
# Chart defaults pin runAsUser 65532, which fails OpenShift restricted-v2 SCC.
# Nulling UID/GID lets the platform assign from the namespace range.
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

echo "==> Kueue ${KUEUE_VERSION} (batch/job + DRA deviceClassMappings)"
helm upgrade --install kueue "${KUEUE_CHART}" \
  --version "${KUEUE_VERSION}" \
  --namespace "${KUEUE_NAMESPACE}" \
  --create-namespace \
  -f "${KUEUE_VALUES}" \
  --wait --timeout 5m

echo ""
echo "------------------------------------------------------------"
echo "==> Operators ready. Install the example chart:"
echo "    helm upgrade --install dra-demo ${SCRIPT_DIR}/.. -n dra-demo --create-namespace"
echo ""
echo "    Note: ClusterQueue DRA quota (example.com/gpu) is 1. Two sample Jobs each"
echo "          claim 1 GPU via ResourceClaimTemplate → second Workload stays Pending."
echo "          Full device allocation also needs a DRA driver + DRA-enabled cluster."
echo "          Verify DRA mapping landed:"
echo "            oc get cm kueue-manager-config -n ${KUEUE_NAMESPACE} -o yaml | grep -A8 deviceClassMappings"
echo "------------------------------------------------------------"
