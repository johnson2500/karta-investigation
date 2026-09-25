#!/usr/bin/env bash
# Verbose OpenShift Workload API path runthrough (Karta + Grove + Kueue, no KAI).
#
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip operator install
#   OC=kubectl        override CLI (default: oc, else kubectl)
set -euo pipefail

NS_DEMO="${NS_DEMO:-demo}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_GROVE="${NS_GROVE:-grove-system}"
NS_KUEUE="${NS_KUEUE:-kueue-system}"
RELEASE="${RELEASE:-demo}"
INTERACTIVE="${INTERACTIVE:-1}"
SKIP_OPERATORS="${SKIP_OPERATORS:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v oc >/dev/null 2>&1; then
  OC="${OC:-oc}"
elif command -v kubectl >/dev/null 2>&1; then
  OC="${OC:-kubectl}"
else
  echo "Need oc or kubectl on PATH" >&2
  exit 1
fi

# --- UI helpers (TTY-aware; degrade cleanly when piped) --------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim 2>/dev/null || true)"
  C_CYAN="$(tput setaf 6)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
  C_BLUE="$(tput setaf 4)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

hr()   { printf '  %s\n' "------------------------------------------------------------"; }
rule() { printf '  %s\n' "+==========================================================+"; }

section() {
  echo ""
  hr
  echo "  ${C_BOLD}${C_CYAN}==> $*${C_RESET}"
  hr
}

why()    { echo "  ${C_DIM}Why this step${C_RESET}     $*"; }
expect() { echo "  ${C_DIM}What you should see${C_RESET} $*"; }
note()   { echo "  ${C_DIM}|${C_RESET} $*"; }

info() { echo "  ${C_BLUE}[info]${C_RESET} $*"; }
ok()   { echo "  ${C_GREEN}[ok]${C_RESET}   $*"; }
warn() { echo "  ${C_YELLOW}[warn]${C_RESET} $*"; }
fail() { echo "  ${C_RED}[FAIL]${C_RESET} $*" >&2; exit 1; }

run() {
  echo "  ${C_DIM}\$${C_RESET} $*"
  "$@"
}

pause() {
  if [[ "${INTERACTIVE}" == "1" ]]; then
    echo ""
    read -r -p "  Press Enter to continue (or Ctrl+C to stop)..."
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

HAS_WORKLOAD_API=0
if "$OC" get crd workloads.scheduling.k8s.io >/dev/null 2>&1; then
  HAS_WORKLOAD_API=1
fi

# --- Opening banner --------------------------------------------------------
echo ""
rule
echo "  ${C_BOLD}|  OpenShift Workload API path (bypass KAI)${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  Can OpenShift run Karta + Grove + Kueue without KAI,"
echo "  |  using the native Workload API for gang contracts?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Karta + Grove + Kueue run on OpenShift without KAI"
note "Grove PCS pods use default-scheduler (not kai-scheduler)"
note "Kueue is the multi-tenant admission path"
note "Workload API (when present) carries gang / placement contract"
note "Karta still maps PodCliqueSet + Job (translation ≠ scheduler)"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "That Workload API CRDs exist on every cluster (optional disable)"
note "KAI GPU topology features (intentionally not installed)"
echo ""

# ---------------------------------------------------------------------------
section "0. Prerequisites"
why "Confirm CLI + cluster access; detect Workload API CRD availability."
expect "oc whoami/nodes succeed; CRD present or chart will disable workloadApi."
# ---------------------------------------------------------------------------
need_cmd helm
need_cmd "$OC"
info "CLI: $OC"
info "Chart directory: $CHART_DIR"
info "Demo namespace: $NS_DEMO"
run "$OC" whoami
run "$OC" get nodes
if [[ "$HAS_WORKLOAD_API" -eq 1 ]]; then
  ok "Workload API CRD present (workloads.scheduling.k8s.io)"
else
  warn "Workload API CRD missing — will set workloadApi.workload.enabled=false only"
  warn "Gang Job + Kueue admission still install (Karta/Grove/default-scheduler path intact)"
fi
pause

# ---------------------------------------------------------------------------
section "1. Install operators (Karta + Grove + Kueue, NO KAI)"
why "Install the OpenShift AI stack pieces — never KAI."
expect "install-operators.sh finishes; Grove may be reused from another namespace."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
else
  info "Uses scripts/install-operators.sh — never installs KAI"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify operators + no KAI"
why "Fail fast if operators are down. KAI may exist elsewhere (e.g. Dynamo); this demo must not require it."
expect "Karta/Kueue Running; grove-operator somewhere; demo later proves default-scheduler."
run "$OC" get pods -n "$NS_KARTA"
run "$OC" get pods -n "$NS_KUEUE"
info "Looking for grove-operator Deployment (any namespace)..."
if "$OC" get pods -A --no-headers 2>/dev/null | grep -qiE 'kai-operator|kai-scheduler'; then
  warn "KAI pods exist on cluster (often Dynamo) — OK if demo pods use default-scheduler"
  run bash -c "$OC get pods -A --no-headers 2>/dev/null | grep -iE 'kai-operator|kai-scheduler' | head -5 || true"
else
  ok "No kai-operator / kai-scheduler pods found cluster-wide"
fi
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
"$OC" get pods -n "$NS_KUEUE" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KUEUE"
if "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'; then
  "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" { print "  [ok]   Grove: " $1 "/" $2 "  " $3 }'
elif "$OC" get pods -n "$NS_GROVE" --no-headers 2>/dev/null | grep -q Running; then
  run "$OC" get pods -n "$NS_GROVE"
  ok "Grove pods Running in $NS_GROVE"
else
  fail "No ready grove-operator Deployment found (checked all namespaces; also empty $NS_GROVE)"
fi
ok "Operators Running; this demo path does not require KAI"
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies maps, PCS, queues, gang Job; optionally skips Workload API objects."
expect "Prior gang Job deleted; Helm release in $NS_DEMO (workloadApi off if CRD absent)."
# ---------------------------------------------------------------------------
HELM_EXTRA=()
if [[ "$HAS_WORKLOAD_API" -ne 1 ]]; then
  # Only skip the native Workload CR — keep the Kueue-labeled gang Job.
  HELM_EXTRA+=(--set workloadApi.workload.enabled=false)
  info "Disabling native Workload CR only (CRD absent); gang Job still installs"
fi
# Kueue owns Job .spec.suspend after admit — delete before Helm recreate.
info "Deleting prior gang Job (ignore if missing) so Helm can recreate it"
run "$OC" delete job gang-training-job -n "$NS_DEMO" --ignore-not-found=true --wait=true || true
run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace "${HELM_EXTRA[@]+"${HELM_EXTRA[@]}"}"
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory"
why "List every demo object before layer-specific checks."
expect "karta, PCS, queues, jobs; Kueue + optional scheduling.k8s.io Workloads."
# ---------------------------------------------------------------------------
run "$OC" get karta
run "$OC" get podcliqueset -n "$NS_DEMO"
run "$OC" get clusterqueue openshift-ai-cluster-queue
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get jobs -n "$NS_DEMO"
run "$OC" get workloads.kueue.x-k8s.io -n "$NS_DEMO" || true
if [[ "$HAS_WORKLOAD_API" -eq 1 ]]; then
  run "$OC" get workloads.scheduling.k8s.io -n "$NS_DEMO" || true
else
  warn "Skipping scheduling.k8s.io Workload list (CRD absent)"
fi
run "$OC" get pods -n "$NS_DEMO" || true
ok "Inventory complete"
pause

# ---------------------------------------------------------------------------
section "4. Grove on default-scheduler"
why "Prove Grove topology runs without KAI on the cluster default scheduler."
expect "PodCliqueSet present; pods have empty/default-scheduler — not kai."
# ---------------------------------------------------------------------------
run "$OC" get podcliqueset -n "$NS_DEMO"
run bash -c "$OC get pods -n $NS_DEMO -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.schedulerName}{\"\\n\"}{end}'" || true
if "$OC" get pods -n "$NS_DEMO" -o jsonpath='{range .items[*]}{.spec.schedulerName}{"\n"}{end}' 2>/dev/null | grep -qi kai; then
  warn "Found kai-scheduler — unexpected for this OpenShift path demo"
else
  ok "Pods use empty/default-scheduler (not KAI)"
fi
pause

# ---------------------------------------------------------------------------
section "5. Kueue admission"
why "Show Kueue as the multi-tenant admission path on this OpenShift stack."
expect "gang-training-job present; LocalQueue + Kueue Workload(s) visible."
# ---------------------------------------------------------------------------
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get jobs -n "$NS_DEMO" || true
run "$OC" get workloads.kueue.x-k8s.io -n "$NS_DEMO" || true
"$OC" get job gang-training-job -n "$NS_DEMO" >/dev/null 2>&1 \
  || fail "Missing gang-training-job — chart should still install it when Workload CRD is absent"
# Wait briefly for Kueue to create a Workload from the Job
for _i in 1 2 3 4 5 6; do
  if "$OC" get workloads.kueue.x-k8s.io -n "$NS_DEMO" --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done
if "$OC" get workloads.kueue.x-k8s.io -n "$NS_DEMO" --no-headers 2>/dev/null | grep -q .; then
  ok "Kueue created Workload(s) for the gang Job — admission path works"
else
  fail "No Kueue Workloads for gang-training-job — check LocalQueue label and Job suspend"
fi
pause

# ---------------------------------------------------------------------------
section "6. Workload API (when available)"
why "When CRDs exist, native Workload CR carries the gang contract (KAI alternative)."
expect "scheduling.k8s.io Workload YAML — or a clear skip if CRD absent."
# ---------------------------------------------------------------------------
if [[ "$HAS_WORKLOAD_API" -eq 1 ]]; then
  run "$OC" get workloads.scheduling.k8s.io -n "$NS_DEMO" -o yaml || true
  run bash -c "$OC get job gang-training-job -n $NS_DEMO -o yaml 2>/dev/null | head -60" || true
  ok "Native Workload CR carries gang contract (KAI alternative)"
else
  warn "Workload API not on this cluster — core stack (Karta/Grove/Kueue) still shown"
  run "$OC" get job -n "$NS_DEMO" || true
fi
pause

# ---------------------------------------------------------------------------
section "7. Karta maps still matter"
why "Bypassing KAI does not remove the need for schema translation."
expect "PCS + batch Job Karta maps still present and readable."
# ---------------------------------------------------------------------------
run bash -c "$OC get karta openshift-ai-grove-podcliqueset-v1alpha1 -o yaml | head -40"
run bash -c "$OC get karta openshift-ai-batch-job-v1 -o yaml | head -40"
ok "Bypassing KAI does not remove the need for schema translation"
pause

# ---------------------------------------------------------------------------
section "8. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  OpenShift AI path (no KAI):
    Karta   — maps PodCliqueSet + Job
    Grove   — clique topology on default-scheduler
    Kueue   — admission / quota
    Workload API — gang / placement contract when CRDs exist

  Useful re-checks:
    $OC get karta
    $OC get podcliqueset,jobs,pods -n $NS_DEMO
    $OC get workloads.kueue.x-k8s.io -n $NS_DEMO
    $OC get workloads.scheduling.k8s.io -n $NS_DEMO   # if CRD present
    $OC get pods -A | grep -i kai || echo no KAI

  Fractional GPUs (optional docs / opt-in samples):
    see fractional-gpus.md

  Cleanup (optional — not run by this script):
    helm uninstall $RELEASE -n $NS_DEMO
    # helm uninstall kueue -n $NS_KUEUE
    # helm uninstall grove-operator -n $NS_GROVE
    # helm uninstall karta -n $NS_KARTA

  Re-run without reinstalling operators:
    SKIP_OPERATORS=1 ./scripts/runthrough.sh

  Non-interactive:
    INTERACTIVE=0 ./scripts/runthrough.sh
EOF
ok "Runthrough finished"
