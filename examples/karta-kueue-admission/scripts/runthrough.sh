#!/usr/bin/env bash
# Verbose Karta + Kueue RayJob admission runthrough (nvidia.com/gpu quota).
#
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip operator install
#   SKIP_CLEAN_JOBS=0 set 1 to leave existing RayJobs as-is before chart install
#   OC=kubectl        override CLI (default: oc, else kubectl)
set -euo pipefail

NS_DEMO="${NS_DEMO:-admit}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_RAY="${NS_RAY:-ray-system}"
NS_KUEUE="${NS_KUEUE:-kueue-system}"
RELEASE="${RELEASE:-admit}"
INTERACTIVE="${INTERACTIVE:-1}"
SKIP_OPERATORS="${SKIP_OPERATORS:-0}"
SKIP_CLEAN_JOBS="${SKIP_CLEAN_JOBS:-0}"

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

workload_admitted_count() {
  local count=0 status w
  for w in $("$OC" get workloads -n "$NS_DEMO" -o name 2>/dev/null || true); do
    status="$("$OC" get "$w" -n "$NS_DEMO" -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# --- Opening banner --------------------------------------------------------
echo ""
rule
echo "  ${C_BOLD}|  Karta + Kueue admission (RayJob GPU quota)${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  With nvidia.com/gpu quota = 1, does Kueue admit one"
echo "  |  RayJob and queue the second — while Karta stays a map?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Layer 1 (Kueue): quota 1 → one RayJob admitted, second waits"
note "Layer 2 (Karta): RayJob map is translation only"
note "Layer 3: pods may stay Pending without real GPUs — still OK"
note "Freeing quota lets the waiter admit (delete admitted RayJob)"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "Real GPU binding / DRA drivers (see karta-kueue-dra)"
note "That Karta admits workloads or places pods"
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
section "1. Install operators (Karta + KubeRay + Kueue)"
why "Need Karta maps, KubeRay for RayJob, and Kueue with RayJob integration."
expect "install-operators.sh finishes; KubeRay may be reused from another namespace."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
  note "Requires Karta + KubeRay + Kueue already Running (KubeRay may be outside ray-system)."
else
  info "Uses scripts/install-operators.sh (+ kueue-values RayJob integration)"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify operators"
why "Fail fast if Karta/Kueue/KubeRay are not actually ready."
expect "Running pods in karta-system + kueue-system; kuberay-operator deploy somewhere."
run "$OC" get pods -n "$NS_KARTA"
run "$OC" get pods -n "$NS_KUEUE"
# KubeRay may live in ray-system OR be reused from OperatorHub / another release.
info "Looking for kuberay-operator Deployment (any namespace)..."
run bash -c "$OC get deploy -A --no-headers 2>/dev/null | grep -iE 'kuberay|ray-operator' || true"
run "$OC" get pods -n "$NS_RAY" || true
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
"$OC" get pods -n "$NS_KUEUE" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KUEUE"
if "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" && $3 ~ /^[1-9]/ { found=1 } END { exit !found }'; then
  "$OC" get deploy -A --no-headers 2>/dev/null \
    | awk '$2 == "kuberay-operator" { print "  [ok]   KubeRay: " $1 "/" $2 "  " $3 }'
elif "$OC" get pods -n "$NS_RAY" --no-headers 2>/dev/null | grep -q Running; then
  run "$OC" get pods -n "$NS_RAY"
  ok "KubeRay pods Running in $NS_RAY"
else
  if [[ "${SKIP_OPERATORS}" == "1" ]]; then
    fail "KubeRay not found — re-run without SKIP_OPERATORS=1 (or install KubeRay first)"
  fi
  fail "No ready kuberay-operator Deployment found (checked all namespaces; also empty $NS_RAY)"
fi
ok "Operator pods are Running"
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies queues, Karta map, and two competing RayJobs."
expect "Fresh RayJobs (unless SKIP_CLEAN_JOBS=1); Helm release in $NS_DEMO."
# ---------------------------------------------------------------------------
if [[ "${SKIP_CLEAN_JOBS}" != "1" ]]; then
  info "Deleting existing sample RayJobs so Workloads are fresh..."
  run "$OC" delete rayjob rayjob-gpu-admit rayjob-gpu-queued -n "$NS_DEMO" --ignore-not-found=true || true
fi

run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory"
why "Confirm map, queues, and both RayJobs landed before watching admission."
expect "karta, clusterqueue, localqueue, and two rayjobs listed."
# ---------------------------------------------------------------------------
run "$OC" get karta admit-ray-io-rayjob-v1
run "$OC" get clusterqueue gpu-cluster-queue
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get rayjob -n "$NS_DEMO"
ok "Inventory complete"
pause

# ---------------------------------------------------------------------------
section "4. ClusterQueue quota — nvidia.com/gpu = 1"
why "Quota of 1 is the reason only one RayJob can hold a logical GPU."
expect "ClusterQueue YAML shows nvidia.com/gpu covered with nominalQuota 1."
# ---------------------------------------------------------------------------
run bash -c "$OC get clusterqueue gpu-cluster-queue -o yaml | grep -A25 'nvidia.com/gpu\|nominalQuota\|coveredResources' | head -40"
if "$OC" get clusterqueue gpu-cluster-queue -o yaml | grep -q 'nvidia.com/gpu'; then
  ok "ClusterQueue covers nvidia.com/gpu"
else
  fail "ClusterQueue missing nvidia.com/gpu"
fi
pause

# ---------------------------------------------------------------------------
section "5. Layer 1 — admit vs queue (wait up to ~60s)"
why "Watch Kueue enforce quota: one Workload Admitted, one pending."
expect "LocalQueue shows admitted≈1 and pending≈1 (or equivalent Workload pair)."
# ---------------------------------------------------------------------------
saw_pair=0
for i in $(seq 1 30); do
  a_count="$(workload_admitted_count)"
  lq_a="$("$OC" get localqueue gpu-local-queue -n "$NS_DEMO" -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null || echo 0)"
  lq_p="$("$OC" get localqueue gpu-local-queue -n "$NS_DEMO" -o jsonpath='{.status.pendingWorkloads}' 2>/dev/null || echo 0)"
  info "attempt ${i}/30  admitted=${a_count}  localqueue admitted=${lq_a} pending=${lq_p}"
  run "$OC" get workloads -n "$NS_DEMO" || true
  run "$OC" get rayjob -n "$NS_DEMO" || true
  if [[ "${a_count}" -ge 1 && "${lq_p:-0}" -ge 1 ]]; then
    saw_pair=1
    break
  fi
  if [[ "${lq_a:-0}" -ge 1 && "${lq_p:-0}" -ge 1 ]]; then
    saw_pair=1
    break
  fi
  sleep 2
done

run "$OC" get localqueue -n "$NS_DEMO"
if [[ "$saw_pair" -eq 1 ]]; then
  ok "Layer 1 success: one admitted, one waiting on quota"
else
  warn "Did not clearly see admit+pending pair — inspect workloads / Kueue RayJob config"
fi
pause

# ---------------------------------------------------------------------------
section "6. Layer 2 — Karta map"
why "Remind that admission and translation are separate layers."
expect "admit-ray-io-rayjob-v1 map YAML; Karta does not decide admit/queue."
# ---------------------------------------------------------------------------
run bash -c "$OC get karta admit-ray-io-rayjob-v1 -o yaml | head -50"
ok "Karta translates RayJob; Kueue admits — separate layers"
pause

# ---------------------------------------------------------------------------
section "7. Layer 3 — pods (Pending OK without GPUs)"
why "Placement is a third layer; Pending pods do not invalidate admission."
expect "Pods may be Pending if the cluster has no real GPUs — that is fine."
# ---------------------------------------------------------------------------
run "$OC" get pods -n "$NS_DEMO" -o wide || true
ok "Pending pods do not invalidate Layer 1 admission"
pause

# ---------------------------------------------------------------------------
section "8. Free quota — delete admitted RayJob"
why "Show admission is dynamic: releasing quota lets the waiter run."
expect "After deleting rayjob-gpu-admit, a remaining Workload becomes Admitted."
# ---------------------------------------------------------------------------
info "Deleting rayjob-gpu-admit to free nvidia.com/gpu quota"
run "$OC" delete rayjob rayjob-gpu-admit -n "$NS_DEMO" --ignore-not-found=true --wait=false || true
for i in $(seq 1 20); do
  a_count="$(workload_admitted_count)"
  info "attempt ${i}/20  admitted_workloads=${a_count}"
  run "$OC" get workloads -n "$NS_DEMO" || true
  run "$OC" get rayjob -n "$NS_DEMO" || true
  if [[ "${a_count}" -ge 1 ]]; then
    ok "A remaining Workload is Admitted after quota release"
    break
  fi
  sleep 2
done
pause

# ---------------------------------------------------------------------------
section "9. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  Three-layer RayJob admission demo:
    Layer 1 (Kueue):  nvidia.com/gpu=1 → admit vs queue
    Layer 2 (Karta):  RayJob schema / PodGroup hints
    Layer 3:          scheduler placement (GPUs optional for this lab)

  Useful re-checks:
    $OC get localqueue,workloads,rayjob -n $NS_DEMO
    $OC get clusterqueue gpu-cluster-queue -o yaml | grep -A10 nvidia.com/gpu

  Cleanup (optional — not run by this script):
    helm uninstall $RELEASE -n $NS_DEMO
    # helm uninstall kueue -n $NS_KUEUE
    # helm uninstall kuberay-operator -n $NS_RAY
    # helm uninstall karta -n $NS_KARTA

  Re-run without reinstalling operators (Karta + KubeRay + Kueue must already be up):
    SKIP_OPERATORS=1 ./scripts/runthrough.sh

  Non-interactive:
    INTERACTIVE=0 ./scripts/runthrough.sh
EOF
ok "Runthrough finished"
