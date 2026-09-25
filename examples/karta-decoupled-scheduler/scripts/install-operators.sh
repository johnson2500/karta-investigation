#!/usr/bin/env bash
# Install Karta (+ Training Operator for PyTorchJob) WITHOUT KAI.
# Optional: document EWI as a consumer; this script never installs KAI/volcano-kai.
set -euo pipefail

KARTA_VERSION="${KARTA_VERSION:-0.2.0}"
# Chart still published at run-ai GHCR; dsx-ai-factory/workload-map OCI path is not published yet.
# Override with KARTA_CHART / KARTA_VERSION if needed.
KARTA_CHART="${KARTA_CHART:-oci://ghcr.io/run-ai/karta/karta}"
KARTA_NAMESPACE="${KARTA_NAMESPACE:-karta-system}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

TRAINING_OPERATOR_VERSION="${TRAINING_OPERATOR_VERSION:-v1.8.1}"
TRAINING_NAMESPACE="${TRAINING_NAMESPACE:-kubeflow}"
# OpenShift AI (ODS) ships Training Operator in this namespace when enabled.
ODS_TRAINING_NAMESPACE="${ODS_TRAINING_NAMESPACE:-redhat-ods-applications}"
ODS_TRAINING_DEPLOY="${ODS_TRAINING_DEPLOY:-kubeflow-training-operator}"
TRAINING_WAIT_TIMEOUT="${TRAINING_WAIT_TIMEOUT:-180}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v oc >/dev/null 2>&1; then
  KUBECTL="${KUBECTL:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  KUBECTL="${KUBECTL:-kubectl}"
else
  echo "Need oc or kubectl on PATH" >&2
  exit 1
fi

karta_helm_failed() {
  echo "" >&2
  echo "==> Karta helm install failed / timed out after ${HELM_TIMEOUT}." >&2
  echo "    Diagnostics:" >&2
  echo "      ${KUBECTL} get deploy,rs,pods -n ${KARTA_NAMESPACE}" >&2
  echo "      ${KUBECTL} get events -n ${KARTA_NAMESPACE} --sort-by=.lastTimestamp | tail -20" >&2
  echo "    Common OpenShift causes:" >&2
  echo "      1) Chart pins runAsUser 65532 → restricted-v2 SCC RejectedCreate (no pods)." >&2
  echo "      2) Chart memory limit 128Mi → OOMKilled / CrashLoopBackOff on busy clusters." >&2
  echo "    This script nulls UID/GID and raises memory; manual install needs the same --set flags." >&2
  echo "    Stuck pending-install / pending-upgrade / failed:" >&2
  echo "      helm uninstall karta -n ${KARTA_NAMESPACE}" >&2
  exit 1
}

# True if Endpoints object for ns/svc has at least one address (webhook-ready).
service_has_endpoints() {
  local ns="$1" svc="$2"
  local addrs
  addrs="$("${KUBECTL}" get endpoints "${svc}" -n "${ns}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "${addrs// /}" ]]
}

deploy_available() {
  local ns="$1" deploy="$2"
  "${KUBECTL}" get deploy "${deploy}" -n "${ns}" >/dev/null 2>&1 || return 1
  local ready
  ready="$("${KUBECTL}" get deploy "${deploy}" -n "${ns}" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -ge 1 ]]
}

# List Fail-policy pytorchjob webhook backends as "namespace/service" lines.
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

# Every Fail-policy pytorchjob webhook must have endpoints (admission calls all of them).
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
      pytorchjob_fail_webhook_backends | while IFS= read -r b; do
        [[ -n "${b}" ]] && echo "      - ${b}"
      done
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "" >&2
  echo "==> Timed out waiting for PyTorchJob webhook endpoints." >&2
  echo "    Backends (failurePolicy=Fail):" >&2
  pytorchjob_fail_webhook_backends | while IFS= read -r b; do
    [[ -z "${b}" ]] && continue
    ns="${b%%/*}"; svc="${b#*/}"
    if service_has_endpoints "${ns}" "${svc}"; then
      echo "      OK  ${b}" >&2
    else
      echo "      BAD ${b} (no endpoints)" >&2
      echo "          ${KUBECTL} get pods,svc,endpoints -n ${ns}" >&2
      echo "          ${KUBECTL} get events -n ${ns} --sort-by=.lastTimestamp | tail -20" >&2
    fi
  done
  echo "    Helm create of PyTorchJob will fail until every Fail webhook has endpoints." >&2
  exit 1
}

# Prefer OpenShift AI's operator when healthy; avoid a second Fail webhook.
ods_training_healthy() {
  deploy_available "${ODS_TRAINING_NAMESPACE}" "${ODS_TRAINING_DEPLOY}" \
    && service_has_endpoints "${ODS_TRAINING_NAMESPACE}" "${ODS_TRAINING_DEPLOY}"
}

# Orphaned standalone webhook (points at kubeflow/training-operator with 0 endpoints)
# blocks CREATE even when ODS is healthy — remove only that ValidatingWebhookConfiguration.
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
  echo "    OpenShift AI webhook remains; PyTorchJob CREATE will use ODS."
  "${KUBECTL}" delete validatingwebhookconfiguration "${vwhc}" --ignore-not-found
}

install_standalone_training_operator() {
  echo "==> Kubeflow Training Operator ${TRAINING_OPERATOR_VERSION} (standalone overlay)"
  # Manifest install keeps the demo free of KAI/Volcano scheduler plugins.
  # Do not treat "CRD already exists" as success — webhook Service must have endpoints.
  if ! "${KUBECTL}" apply -k \
    "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=${TRAINING_OPERATOR_VERSION}"; then
    echo "    apply -k failed; check network / GitHub access" >&2
    exit 1
  fi
  echo "    Waiting for deployment/${TRAINING_NAMESPACE}/training-operator"
  "${KUBECTL}" rollout status "deployment/training-operator" \
    -n "${TRAINING_NAMESPACE}" --timeout="${TRAINING_WAIT_TIMEOUT}s"
}

echo ""
echo "------------------------------------------------------------"
echo "==> Installing operators: Karta + Training Operator (NO KAI)"
echo "    (OpenShift SCC/memory fixes; waits for PyTorchJob webhooks)"
echo "------------------------------------------------------------"
echo ""

echo "==> Karta ${KARTA_VERSION} (no KAI dependency; OpenShift-friendly UID + memory)"
# Chart defaults pin runAsUser 65532 (fails OpenShift restricted-v2) and 128Mi limit
# (OOMKills on CRD-heavy clusters). Null UID/GID; raise memory so --wait can succeed.
echo "    helm upgrade --install into ${KARTA_NAMESPACE} (--wait --timeout ${HELM_TIMEOUT})"
echo "    Progress: watch '${KUBECTL} get events,pods -n ${KARTA_NAMESPACE}' if this pauses after Pulled."
helm upgrade --install karta "${KARTA_CHART}" \
  --version "${KARTA_VERSION}" \
  --namespace "${KARTA_NAMESPACE}" \
  --create-namespace \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi \
  --wait --timeout "${HELM_TIMEOUT}" \
  || karta_helm_failed

echo "==> Training Operator (PyTorchJob CRD + validating webhook)"
if ods_training_healthy; then
  echo "    OpenShift AI Training Operator healthy in ${ODS_TRAINING_NAMESPACE}"
  echo "    Skipping upstream standalone install (avoids a second Fail webhook)."
  remove_orphaned_standalone_webhook
elif deploy_available "${TRAINING_NAMESPACE}" "training-operator" \
  || "${KUBECTL}" get deploy "training-operator" -n "${TRAINING_NAMESPACE}" >/dev/null 2>&1; then
  echo "    Found deployment/${TRAINING_NAMESPACE}/training-operator — ensuring ready"
  "${KUBECTL}" rollout status "deployment/training-operator" \
    -n "${TRAINING_NAMESPACE}" --timeout="${TRAINING_WAIT_TIMEOUT}s" || install_standalone_training_operator
else
  install_standalone_training_operator
fi

wait_for_pytorchjob_webhooks "${TRAINING_WAIT_TIMEOUT}"

if ! "${KUBECTL}" get crd pytorchjobs.kubeflow.org >/dev/null 2>&1; then
  echo "==> pytorchjobs.kubeflow.org CRD missing after Training Operator setup" >&2
  exit 1
fi

echo ""
echo "==> External Workload Integrator (EWI)"
echo "    EWI is the Run:ai consumer that reads Karta maps and materializes"
echo "    PodGroup / hierarchy metadata. It is NOT KAI and does not replace"
echo "    kube-scheduler. On a full Run:ai install, deploy EWI from your"
echo "    platform package; for this OpenShift PoC the chart annotates"
echo "    illustrative PodGroup metadata derived from the Karta map."
echo ""
echo ""
echo "------------------------------------------------------------"
echo "==> Operators ready (scheduler = cluster default). Install the example:"
echo "    helm upgrade --install decoupled ${SCRIPT_DIR}/.. -n decoupled --create-namespace"
echo "------------------------------------------------------------"
