#!/usr/bin/env bash
# Install shared operators for all run-ai-karta demos (gallery hub path).
# Always: Karta + Kueue (RayJob + DRA mappings) + Grove + KubeRay.
# Optional: Training Operator when INSTALL_TRAINING_OPERATOR=1 (default).
#
# Reuse-if-running for Grove / KubeRay / Training (OpenShift AI). Force with:
#   FORCE_GROVE_INSTALL=1 FORCE_KUBERAY_INSTALL=1
set -euo pipefail

KARTA_VERSION="${KARTA_VERSION:-0.2.0}"
KARTA_CHART="${KARTA_CHART:-oci://ghcr.io/run-ai/karta/karta}"
KARTA_NAMESPACE="${KARTA_NAMESPACE:-karta-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

GROVE_VERSION="${GROVE_VERSION:-v0.1.0-alpha.10-rc1}"
GROVE_CHART="${GROVE_CHART:-oci://ghcr.io/ai-dynamo/grove/grove-charts}"
GROVE_NAMESPACE="${GROVE_NAMESPACE:-grove-system}"

KUEUE_VERSION="${KUEUE_VERSION:-0.19.5}"
KUEUE_CHART="${KUEUE_CHART:-oci://registry.k8s.io/kueue/charts/kueue}"
KUEUE_NAMESPACE="${KUEUE_NAMESPACE:-kueue-system}"

KUBERAY_VERSION="${KUBERAY_VERSION:-1.3.2}"
KUBERAY_CHART="${KUBERAY_CHART:-kuberay/kuberay-operator}"
KUBERAY_NAMESPACE="${KUBERAY_NAMESPACE:-ray-system}"

INSTALL_TRAINING_OPERATOR="${INSTALL_TRAINING_OPERATOR:-1}"
TRAINING_OPERATOR_VERSION="${TRAINING_OPERATOR_VERSION:-v1.8.1}"
TRAINING_NAMESPACE="${TRAINING_NAMESPACE:-kubeflow}"
ODS_TRAINING_NAMESPACE="${ODS_TRAINING_NAMESPACE:-redhat-ods-applications}"
ODS_TRAINING_DEPLOY="${ODS_TRAINING_DEPLOY:-kubeflow-training-operator}"
TRAINING_WAIT_TIMEOUT="${TRAINING_WAIT_TIMEOUT:-180}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROVE_VALUES="${SCRIPT_DIR}/grove-values.yaml"
KUEUE_VALUES="${SCRIPT_DIR}/kueue-values.yaml"

if command -v oc >/dev/null 2>&1; then
  KUBECTL="${KUBECTL:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL="${KUBECTL:-kubectl}"
else
  echo "Need oc or kubectl on PATH" >&2
  exit 1
fi

deploy_available() {
  local ns="$1" deploy="$2"
  "${KUBECTL}" get deploy "${deploy}" -n "${ns}" >/dev/null 2>&1 || return 1
  local ready
  ready="$("${KUBECTL}" get deploy "${deploy}" -n "${ns}" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -ge 1 ]]
}

service_has_endpoints() {
  local ns="$1" svc="$2"
  local addrs
  addrs="$("${KUBECTL}" get endpoints "${svc}" -n "${ns}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "${addrs// /}" ]]
}

grove_already_running() {
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'
}

kuberay_already_running() {
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'
}

ods_training_healthy() {
  deploy_available "${ODS_TRAINING_NAMESPACE}" "${ODS_TRAINING_DEPLOY}" \
    && service_has_endpoints "${ODS_TRAINING_NAMESPACE}" "${ODS_TRAINING_DEPLOY}"
}

remove_orphaned_standalone_webhook() {
  local vwhc="validator.training-operator.kubeflow.org"
  "${KUBECTL}" get validatingwebhookconfiguration "${vwhc}" >/dev/null 2>&1 || return 0
  if service_has_endpoints "${TRAINING_NAMESPACE}" "training-operator"; then
    return 0
  fi
  if deploy_available "${TRAINING_NAMESPACE}" "training-operator"; then
    return 0
  fi
  echo "    Removing orphaned ${vwhc} (no endpoints behind ${TRAINING_NAMESPACE}/training-operator)"
  "${KUBECTL}" delete validatingwebhookconfiguration "${vwhc}" --ignore-not-found
}

install_standalone_training_operator() {
  echo "==> Kubeflow Training Operator ${TRAINING_OPERATOR_VERSION} (standalone overlay)"
  if ! "${KUBECTL}" apply -k \
    "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${TRAINING_OPERATOR_VERSION}"; then
    echo "    apply -k failed; check network / GitHub access" >&2
    exit 1
  fi
  echo "    Waiting for deployment/${TRAINING_NAMESPACE}/training-operator"
  "${KUBECTL}" rollout status "deployment/training-operator" \
    -n "${TRAINING_NAMESPACE}" --timeout="${TRAINING_WAIT_TIMEOUT}s"
}

pytorchjob_fail_webhook_backends() {
  "${KUBECTL}" get validatingwebhookconfiguration -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
seen = set()
for item in data.get("items", []):
    for wh in item.get("webhooks", []):
        name = wh.get("name", "")
        if "pytorchjob" not in name.lower():
            continue
        if wh.get("failurePolicy", "Fail") != "Fail":
            continue
        svc = (wh.get("clientConfig") or {}).get("service") or {}
        ns, sn = svc.get("namespace"), svc.get("name")
        if ns and sn:
            key = f"{ns}/{sn}"
            if key not in seen:
                seen.add(key)
                print(key)
' 2>/dev/null || true
}

all_pytorchjob_webhooks_ready() {
  local backends backend ns svc
  backends="$(pytorchjob_fail_webhook_backends)"
  [[ -n "${backends}" ]] || return 1
  while IFS= read -r backend; do
    [[ -n "${backend}" ]] || continue
    ns="${backend%%/*}"
    svc="${backend#*/}"
    service_has_endpoints "${ns}" "${svc}" || return 1
  done <<< "${backends}"
  return 0
}

wait_for_pytorchjob_webhooks() {
  local timeout="${1:-${TRAINING_WAIT_TIMEOUT}}"
  local elapsed=0
  echo "    Waiting up to ${timeout}s for PyTorchJob validating webhook endpoints..."
  while (( elapsed < timeout )); do
    if all_pytorchjob_webhooks_ready; then
      echo "    PyTorchJob validating webhook(s) have endpoints — ready"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "==> Timed out waiting for PyTorchJob webhook endpoints." >&2
  exit 1
}

echo ""
echo "------------------------------------------------------------"
echo "==> Shared operators for Karta demo gallery"
echo "    Karta + Kueue + Grove + KubeRay"
if [[ "${INSTALL_TRAINING_OPERATOR}" == "1" ]]; then
  echo "    + Training Operator (INSTALL_TRAINING_OPERATOR=1)"
fi
echo "------------------------------------------------------------"
echo ""

echo "==> Karta ${KARTA_VERSION} (OpenShift-friendly: no fixed runAsUser)"
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
    echo "==> Karta helm failed/timed out. Check: oc get events -n ${KARTA_NAMESPACE}" >&2
    echo "    Stuck release: helm uninstall karta -n ${KARTA_NAMESPACE}" >&2
    exit 1
  }

echo "==> Grove ${GROVE_VERSION} (default-scheduler only)"
if [[ "${FORCE_GROVE_INSTALL:-0}" != "1" ]] && grove_already_running; then
  echo "    Grove operator already Running — reusing it (skip helm install)."
  kubectl get deploy -A --no-headers 2>/dev/null | awk '$2 == "grove-operator" { print "      " $1 "/" $2 "  " $3 }'
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
      echo "==> Grove helm failed. Reuse existing (default) or SKIP_GROVE_CRDS=1." >&2
      exit 1
    }
fi

echo "==> Kueue ${KUEUE_VERSION} (RayJob frameworks + DRA deviceClassMappings)"
helm upgrade --install kueue "${KUEUE_CHART}" \
  --version "${KUEUE_VERSION}" \
  --namespace "${KUEUE_NAMESPACE}" \
  --create-namespace \
  -f "${KUEUE_VALUES}" \
  --wait --timeout "${HELM_TIMEOUT}"

echo "==> KubeRay operator ${KUBERAY_VERSION}"
if [[ "${FORCE_KUBERAY_INSTALL:-0}" != "1" ]] && kuberay_already_running; then
  echo "    KubeRay operator already Running — reusing it (skip helm install)."
  kubectl get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" { print "      " $1 "/" $2 "  " $3 }'
else
  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
  helm repo update kuberay >/dev/null
  helm upgrade --install kuberay-operator "${KUBERAY_CHART}" \
    --version "${KUBERAY_VERSION}" \
    --namespace "${KUBERAY_NAMESPACE}" \
    --create-namespace \
    --wait --timeout "${HELM_TIMEOUT}" \
    || {
      echo "==> KubeRay helm failed. Confirm existing operator or set FORCE_KUBERAY_INSTALL=1." >&2
      exit 1
    }
fi

if [[ "${INSTALL_TRAINING_OPERATOR}" == "1" ]]; then
  echo "==> Training Operator (PyTorchJob — for karta-decoupled-scheduler)"
  if ods_training_healthy; then
    echo "    OpenShift AI Training Operator healthy in ${ODS_TRAINING_NAMESPACE}"
    echo "    Skipping upstream standalone install."
    remove_orphaned_standalone_webhook
  elif deploy_available "${TRAINING_NAMESPACE}" "training-operator" \
    || "${KUBECTL}" get deploy "training-operator" -n "${TRAINING_NAMESPACE}" >/dev/null 2>&1; then
    echo "    Found deployment/${TRAINING_NAMESPACE}/training-operator — ensuring ready"
    "${KUBECTL}" rollout status "deployment/training-operator" \
      -n "${TRAINING_NAMESPACE}" --timeout="${TRAINING_WAIT_TIMEOUT}s" \
      || install_standalone_training_operator
  else
    install_standalone_training_operator
  fi
  wait_for_pytorchjob_webhooks "${TRAINING_WAIT_TIMEOUT}"
  if ! "${KUBECTL}" get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
    echo "==> pytorchjobs.kubeflow.org CRD missing after Training Operator setup" >&2
    exit 1
  fi
else
  echo "==> Skipping Training Operator (INSTALL_TRAINING_OPERATOR=0)"
fi

echo ""
echo "------------------------------------------------------------"
echo "==> Shared operators ready. Install the gallery hub:"
echo "    helm upgrade --install karta-hub ${SCRIPT_DIR}/.. -n karta-hub --create-namespace"
echo "    (Build the image first — see README / NOTES.)"
echo "------------------------------------------------------------"
