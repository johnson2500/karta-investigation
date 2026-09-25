#!/usr/bin/env bash
# Verbose Karta + Grove + Kueue demo runthrough.
# Prints each command, expected checks, and what that step proves.
#
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip operator install (operators already up)
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

# --- Opening banner --------------------------------------------------------
echo ""
rule
echo "  ${C_BOLD}|  Karta + Grove + Kueue${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  Can Grove topology, Kueue admission, and Karta maps"
echo "  |  coexist on OpenShift without conflating their roles?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Grove owns PodCliqueSet clique shape on default-scheduler"
note "Kueue admits two sample batch/v1 Jobs via one LocalQueue"
note "Karta maps PodCliqueSet AND batch/v1 Job (translation only)"
note "One Job map covers both sample Jobs (no per-name Karta)"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "GPU placement / KAI scheduling (not installed here)"
note "That Karta admits jobs or replaces Grove/Kueue"
echo ""

# ---------------------------------------------------------------------------
section "0. Prerequisites"
why "Confirm CLI + cluster access before installing anything."
expect "oc whoami and nodes succeed; demo namespace defaults shown."
# ---------------------------------------------------------------------------
need_cmd helm
need_cmd "$OC"
info "CLI: $OC"
info "Chart directory: $CHART_DIR"
info "Demo namespace: $NS_DEMO"
run "$OC" whoami
run "$OC" get nodes
ok "Cluster access works"
pause

# ---------------------------------------------------------------------------
section "1. Install operators (Karta + Grove + Kueue)"
why "Operators must be Running before the demo chart can create PCS / Jobs / queues."
expect "install-operators.sh finishes; Grove may be reused from another namespace."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
else
  info "Uses scripts/install-operators.sh (Grove with default-scheduler only)"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify operators"
why "Fail fast if Karta/Kueue/Grove are not actually ready."
expect "Running pods in karta-system + kueue-system; grove-operator deploy somewhere."
run "$OC" get pods -n "$NS_KARTA"
run "$OC" get pods -n "$NS_KUEUE"
# Grove may live in grove-system OR be reused from another release (e.g. Dynamo → dynamo-platform).
info "Looking for grove-operator Deployment (any namespace)..."
run bash -c "$OC get deploy -A --no-headers 2>/dev/null | grep grove-operator || true"
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
"$OC" get pods -n "$NS_KUEUE" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KUEUE"
if "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'; then
  "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "grove-operator" { print "  [ok]   Grove: " $1 "/" $2 "  " $3 }'
else
  # Fall back to pods in NS_GROVE for a dedicated install.
  if "$OC" get pods -n "$NS_GROVE" --no-headers 2>/dev/null | grep -q Running; then
    run "$OC" get pods -n "$NS_GROVE"
    ok "Grove pods Running in $NS_GROVE"
  else
    fail "No ready grove-operator Deployment found (checked all namespaces; also empty $NS_GROVE)"
  fi
fi
ok "Operator pods are Running"
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies Karta maps, Grove PCS, Kueue queues, and two sample Jobs."
expect "Helm release lands in $NS_DEMO; prior Jobs deleted to avoid suspend conflicts."
# ---------------------------------------------------------------------------
info "Installing: Karta maps, Grove PCS, Kueue queues, two sample Jobs"
# Kueue owns Job .spec.suspend after admit/unsuspend. Helm SSA upgrade conflicts
# if we re-apply suspend:true ("conflict with kueue ... .spec.suspend").
# Jobs are one-shot — delete before refresh so Helm can recreate them.
info "Deleting prior sample Jobs (ignore if missing) so Helm can recreate them"
run "$OC" delete job kueue-demo-job openshift-batch-job -n "$NS_DEMO" --ignore-not-found=true --wait=true || true
run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory"
why "Sanity-check that every demo object exists before diving into layers."
expect "karta, podcliqueset, clusterqueue, localqueue, jobs listed in $NS_DEMO."
# ---------------------------------------------------------------------------
run "$OC" get karta
run "$OC" get podcliqueset -n "$NS_DEMO"
run "$OC" get clusterqueue demo-cluster-queue
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get jobs -n "$NS_DEMO"
run "$OC" get pods -n "$NS_DEMO" || true
ok "Inventory complete"
pause

# ---------------------------------------------------------------------------
section "4. Grove path — topology"
why "Show Grove owns clique shape; Karta only publishes how to read PodCliqueSet."
expect "grove-demo PCS present; Karta map grove-kueue-podcliqueset-v1alpha1 readable."
# ---------------------------------------------------------------------------
info "Grove owns clique shape; Karta only maps how to read PodCliqueSet"
run "$OC" get podcliqueset grove-demo -n "$NS_DEMO"
run "$OC" get pods -n "$NS_DEMO" || true
run bash -c "$OC get karta grove-kueue-podcliqueset-v1alpha1 -o yaml | head -60"
ok "Grove PCS + Karta map present"
pause

# ---------------------------------------------------------------------------
section "5. Kueue path — Job admission (wait up to ~60s)"
why "Prove Kueue admits both sample Jobs under one LocalQueue quota."
expect "Two Jobs and at least one Workload; Admitted conditions appear."
# ---------------------------------------------------------------------------
info "Expect both sample Jobs admitted (quota sized for both)"
saw=0
for i in $(seq 1 30); do
  jobs="$("$OC" get jobs -n "$NS_DEMO" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  wl="$("$OC" get workloads -n "$NS_DEMO" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "attempt ${i}/30  jobs=${jobs} workloads=${wl}"
  run "$OC" get jobs -n "$NS_DEMO" || true
  run "$OC" get workloads -n "$NS_DEMO" || true
  if [[ "${jobs}" -ge 2 && "${wl}" -ge 1 ]]; then
    saw=1
    break
  fi
  sleep 2
done
run "$OC" get localqueue -n "$NS_DEMO"
if [[ "$saw" -eq 1 ]]; then
  ok "Jobs and Workloads visible — check Admitted conditions above"
else
  warn "Jobs/Workloads slow to appear — inspect: oc describe jobs -n $NS_DEMO"
fi
pause

# ---------------------------------------------------------------------------
section "6. One Job Karta covers OpenShift-style batch"
why "Show a single batch/v1 map covers both generic and OpenShift-styled Jobs."
expect "grove-kueue-batch-job-v1 Karta + openshift-batch-job present; no per-name map."
# ---------------------------------------------------------------------------
info "openshift-batch-job uses the same batch/v1 API + grove-kueue-batch-job-v1 map"
run "$OC" get karta grove-kueue-batch-job-v1
run "$OC" get job openshift-batch-job -n "$NS_DEMO" -o yaml 2>/dev/null | head -40 || true
ok "Single Job map; no per-name Karta required"
pause

# ---------------------------------------------------------------------------
section "7. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  Coexistence demo:
    Grove  — PodCliqueSet topology (default-scheduler)
    Kueue  — admits kueue-demo-job + openshift-batch-job
    Karta  — maps PodCliqueSet and batch/v1 Job (translation only)

  Useful re-checks:
    $OC get karta
    $OC get podcliqueset,pods,jobs,workloads -n $NS_DEMO
    $OC get localqueue -n $NS_DEMO

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
