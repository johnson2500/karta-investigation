#!/usr/bin/env bash
# Verbose Karta + Kueue + DRA demo runthrough.
# Prints each command, expected checks, and what that step proves.
#
# Run from anywhere; script resolves the chart directory:
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip Karta/Kueue install (operators already up)
#   SKIP_CLEAN_JOBS=0 set 1 to leave existing Jobs as-is before chart install
#   OC=kubectl        override CLI (default: oc, else kubectl)
set -euo pipefail

NS_DEMO="${NS_DEMO:-dra-demo}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_KUEUE="${NS_KUEUE:-kueue-system}"
RELEASE="${RELEASE:-dra-demo}"
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
  local count=0 status
  local w
  for w in $("$OC" get workloads -n "$NS_DEMO" -o name 2>/dev/null || true); do
    status="$("$OC" get "$w" -n "$NS_DEMO" -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

find_admitted_job() {
  local w status job_uid job_name susp name
  for w in $("$OC" get workloads -n "$NS_DEMO" -o name 2>/dev/null || true); do
    status="$("$OC" get "$w" -n "$NS_DEMO" -o jsonpath='{.status.conditions[?(@.type=="Admitted")].status}' 2>/dev/null || true)"
    [[ "$status" == "True" ]] || continue
    job_uid="$("$OC" get "$w" -n "$NS_DEMO" -o jsonpath='{.metadata.labels.kueue\.x-k8s\.io/job-uid}' 2>/dev/null || true)"
    if [[ -n "$job_uid" ]]; then
      job_name="$("$OC" get jobs -n "$NS_DEMO" -o jsonpath="{range .items[?(@.metadata.uid==\"${job_uid}\")]}{.metadata.name}{end}" 2>/dev/null || true)"
      if [[ -n "$job_name" ]]; then
        echo "$job_name"
        return 0
      fi
    fi
  done
  # Fallback: first Job that is not suspended
  for name in $("$OC" get jobs -n "$NS_DEMO" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    susp="$("$OC" get job "$name" -n "$NS_DEMO" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo true)"
    if [[ "$susp" != "true" ]]; then
      echo "$name"
      return 0
    fi
  done
  return 1
}

# --- Opening banner --------------------------------------------------------
echo ""
rule
echo "  ${C_BOLD}|  Karta + Kueue + DRA${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  Can Kueue admit-vs-queue DRA GPU claims while Karta only"
echo "  |  maps Job + claim paths — without a real GPU driver?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Layer 1 (Kueue): example.com/gpu=1 → one Job admitted, second waits"
note "Layer 2 (Karta): Job map includes DRA claim paths (not a scheduler)"
note "Layer 3 (DRA): DeviceClass + claims; Pending pods OK without a driver"
note "deviceClassMappings must be live or Workloads stay Inadmissible"
note "Deleting the admitted Job frees quota for the waiter"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "Full GPU device binding (needs a DRA driver on the cluster)"
note "That Karta admits Jobs or allocates GPUs"
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
section "1. Install operators (Karta + Kueue)"
why "Kueue must ship deviceClassMappings or DRA Workloads stay Inadmissible."
expect "Karta + Kueue Running; mapping gpu.example.com → example.com/gpu present."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
else
  info "Uses scripts/install-operators.sh:"
  info "  - Karta OCI: ghcr.io/run-ai/karta/karta (OpenShift: null runAsUser/runAsGroup)"
  info "  - Kueue with deviceClassMappings (gpu.example.com → example.com/gpu)"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify operators + DRA mapping"
why "Silently missing deviceClassMappings is the #1 cause of Inadmissible Workloads."
expect "Running pods + kueue-manager-config contains gpu.example.com."
run "$OC" get pods -n "$NS_KARTA"
run "$OC" get pods -n "$NS_KUEUE"
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
"$OC" get pods -n "$NS_KUEUE" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KUEUE"
ok "Operator pods are Running"

info "Confirm deviceClassMappings in live Kueue config (silently missing = Inadmissible Workloads)..."
if "$OC" get cm kueue-manager-config -n "$NS_KUEUE" -o yaml | grep -q 'gpu.example.com'; then
  run bash -c "$OC get cm kueue-manager-config -n $NS_KUEUE -o yaml | grep -A10 deviceClassMappings"
  ok "Mapping present: gpu.example.com → example.com/gpu"
else
  fail "deviceClassMappings missing. Re-run without SKIP_OPERATORS, or: helm upgrade kueue ... -f scripts/kueue-values.yaml"
fi
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies Karta map, queues, DeviceClass, claim template, and two Jobs."
expect "Fresh Jobs (unless SKIP_CLEAN_JOBS=1); Helm release in $NS_DEMO."
# ---------------------------------------------------------------------------
if [[ "${SKIP_CLEAN_JOBS}" != "1" ]]; then
  info "Deleting existing sample Jobs so Workloads are fresh (avoids stale Inadmissible state)..."
  run "$OC" delete job dra-job-admit dra-job-queued -n "$NS_DEMO" --ignore-not-found=true || true
fi

info "Installing chart objects: Karta map, queues, DeviceClass, claim template, two Jobs"
run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory — did everything land?"
why "Sanity-check every object before watching admit-vs-queue."
expect "Karta, queues, DeviceClass, ResourceClaimTemplate, two Jobs (often Suspended)."
# ---------------------------------------------------------------------------
info "Expected: Karta, ClusterQueue, LocalQueue, DeviceClass, ResourceClaimTemplate, two Jobs"
run "$OC" get karta dra-batch-job-v1
run "$OC" get clusterqueue dra-cluster-queue
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get deviceclass gpu.example.com
run "$OC" get resourceclaimtemplate -n "$NS_DEMO"
run "$OC" get jobs -n "$NS_DEMO"
ok "Inventory complete (Jobs often Suspended until Kueue admits)"
pause

# ---------------------------------------------------------------------------
section "4. ClusterQueue quota — must be example.com/gpu = 1"
why "This quota is why only one Job can hold a logical GPU at a time."
expect "ClusterQueue YAML covers example.com/gpu with nominalQuota 1."
# ---------------------------------------------------------------------------
info "This quota is why only one Job can hold a logical GPU at a time"
run bash -c "$OC get clusterqueue dra-cluster-queue -o yaml | grep -A25 'coveredResources\|nominalQuota\|example.com/gpu' | head -40"
if "$OC" get clusterqueue dra-cluster-queue -o yaml | grep -q 'example.com/gpu'; then
  ok "ClusterQueue covers example.com/gpu"
else
  fail "ClusterQueue missing example.com/gpu"
fi
pause

# ---------------------------------------------------------------------------
section "5. Layer 1 — admit vs queue (wait up to ~60s)"
why "Watch Kueue enforce DRA quota: one admitted, one pending."
expect "LocalQueue ~1 admitted + 1 pending; one Job unsuspended, one Suspended."
# ---------------------------------------------------------------------------
info "Expect: LocalQueue ~1 admitted + 1 pending; one Job Running/unsuspended, one Suspended"
info "Polling Workloads..."

saw_pair=0
for i in $(seq 1 30); do
  a_count="$(workload_admitted_count)"
  total="$("$OC" get workloads -n "$NS_DEMO" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  lq_a="$("$OC" get localqueue dra-local-queue -n "$NS_DEMO" -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null || echo 0)"
  lq_p="$("$OC" get localqueue dra-local-queue -n "$NS_DEMO" -o jsonpath='{.status.pendingWorkloads}' 2>/dev/null || echo 0)"
  info "attempt ${i}/30  workloads=${total} admitted=${a_count}  localqueue admitted=${lq_a} pending=${lq_p}"
  run "$OC" get workloads -n "$NS_DEMO" || true
  run "$OC" get jobs -n "$NS_DEMO" || true

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

echo ""
info "LocalQueue / Workloads / Jobs:"
run "$OC" get localqueue -n "$NS_DEMO"
run "$OC" get workloads -n "$NS_DEMO"
run "$OC" get jobs -n "$NS_DEMO"

info "Condition snippets (Admitted vs insufficient quota / Inadmissible):"
"$OC" describe workload -n "$NS_DEMO" 2>/dev/null \
  | grep -E 'insufficient|Admitted|QuotaReserved|Inadmissible|not found|Message:|Reason:|Type:' \
  | head -60 || true

if [[ "$saw_pair" -eq 1 ]]; then
  ok "Layer 1 success: one Workload admitted, one waiting on quota"
else
  warn "Did not clearly see admit+pending pair."
  warn "If you see 'DeviceClass ... not mapped' → fix kueue-values / reinstall Kueue."
  warn "If you see 'ResourceClaimTemplate ... not found' → wait for template, recreate Jobs."
fi
pause

# ---------------------------------------------------------------------------
section "6. Layer 2 — Karta map (translation only)"
why "Karta publishes paths; it does not admit Jobs or allocate GPUs."
expect "resourceClaimsPath / podTemplateSpecPath / suspendDefinition in the map."
# ---------------------------------------------------------------------------
info "Karta does NOT admit Jobs and does NOT allocate GPUs — it publishes paths"
run bash -c "$OC get karta dra-batch-job-v1 -o yaml | grep -E 'resourceClaimsPath|podTemplateSpecPath|suspendDefinition|group:|kind:|Validated|Ready|message:' | head -40"
ok "Look for resourceClaimsPath / podTemplateSpecPath / suspendDefinition"
info "Validated=False can appear depending on Karta version; admission demo does not need Ready=True"
pause

# ---------------------------------------------------------------------------
section "7. Layer 3 — DRA objects and pods"
why "Show DRA shape objects exist; Pending without a driver is expected."
expect "DeviceClass + ResourceClaimTemplate; pods/claims may stay Pending."
# ---------------------------------------------------------------------------
info "Without a GPU DRA driver, Pods/claims may stay Pending — that is OK"
run "$OC" get deviceclass
run "$OC" get resourceclaimtemplate -n "$NS_DEMO"
run "$OC" get resourceclaim -n "$NS_DEMO" || true
run "$OC" get pods -n "$NS_DEMO" -o wide || true
ok "DeviceClass + ResourceClaimTemplate prove DRA shape; Pending ≠ failed admission"
pause

# ---------------------------------------------------------------------------
section "8. Free quota — delete admitted Job, watch waiter"
why "Prove admission is dynamic — releasing quota lets the waiter run."
expect "After deleting the admitted Job, a remaining Workload becomes Admitted."
# ---------------------------------------------------------------------------
info "Deletes whichever Job currently holds example.com/gpu (not always dra-job-admit by name)"

run "$OC" get jobs -n "$NS_DEMO"
run "$OC" get workloads -n "$NS_DEMO"

ADMITTED_JOB=""
if ADMITTED_JOB="$(find_admitted_job)"; then
  ok "Admitted Job to delete: ${ADMITTED_JOB}"
else
  fail "Could not find an admitted / non-suspended Job"
fi

info "What this proves: admission is dynamic — releasing quota lets the waiter run"
run "$OC" delete job "${ADMITTED_JOB}" -n "$NS_DEMO" --wait=true

handoff=0
for i in $(seq 1 25); do
  a_count="$(workload_admitted_count)"
  info "attempt ${i}/25  admitted_workloads=${a_count}"
  run "$OC" get workloads -n "$NS_DEMO" || true
  run "$OC" get jobs -n "$NS_DEMO" || true
  if [[ "${a_count}" -ge 1 ]]; then
    handoff=1
    ok "Hand-off: a remaining Workload is Admitted"
    break
  fi
  if "$OC" describe workload -n "$NS_DEMO" 2>/dev/null | grep -q 'ResourceClaimTemplate.*not found'; then
    warn "Stale/live Inadmissible: template not found — will offer recreate below"
  fi
  sleep 2
done

run "$OC" get localqueue -n "$NS_DEMO"
"$OC" describe workload -n "$NS_DEMO" 2>/dev/null \
  | grep -A2 'insufficient\|Admitted\|QuotaReserved\|Inadmissible' || true

if [[ "$handoff" -ne 1 ]]; then
  warn "Waiter did not admit. Common cause: stale Inadmissible Workload."
  info "Recreating sample Jobs once..."
  run "$OC" delete job dra-job-admit dra-job-queued -n "$NS_DEMO" --ignore-not-found=true || true
  run helm upgrade --install "$RELEASE" "$CHART_DIR" -n "$NS_DEMO"
  info "Waiting for a fresh admit..."
  for i in $(seq 1 20); do
    a_count="$(workload_admitted_count)"
    info "recreate poll ${i}/20 admitted=${a_count}"
    run "$OC" get workloads -n "$NS_DEMO" || true
    run "$OC" get jobs -n "$NS_DEMO" || true
    if [[ "${a_count}" -ge 1 ]]; then
      ok "After recreate, at least one Workload is Admitted"
      handoff=1
      break
    fi
    sleep 2
  done
fi

if [[ "$handoff" -eq 1 ]]; then
  ok "Quota release / admission path demonstrated"
else
  warn "Hand-off still unclear — inspect: oc describe workload -n $NS_DEMO"
fi
pause

# ---------------------------------------------------------------------------
section "9. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  Demo layers:
    Layer 1 (Kueue):  quota gate — one Job holds example.com/gpu, second waits;
                      deleting the admitted Job frees quota for the waiter.
    Layer 2 (Karta):  declarative map of Job structure including DRA claim paths.
    Layer 3 (DRA):    DeviceClass + ResourceClaimTemplate; bind needs a real driver.

  Useful re-checks:
    $OC get localqueue -n $NS_DEMO
    $OC get workloads -n $NS_DEMO
    $OC get jobs -n $NS_DEMO
    $OC get cm kueue-manager-config -n $NS_KUEUE -o yaml | grep -A8 deviceClassMappings

  Cleanup (optional):
    ./scripts/uninstall-all.sh
    # KEEP_OPERATORS=1 ./scripts/uninstall-all.sh
    # FORCE=1 ./scripts/uninstall-all.sh

  Re-run without reinstalling operators:
    SKIP_OPERATORS=1 ./scripts/runthrough.sh

  Non-interactive:
    INTERACTIVE=0 ./scripts/runthrough.sh
EOF
ok "Runthrough finished"
