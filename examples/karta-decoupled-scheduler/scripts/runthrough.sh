#!/usr/bin/env bash
# Verbose Karta decoupled-scheduler runthrough (no KAI).
#
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip operator install
#   OC=kubectl        override CLI (default: oc, else kubectl)
set -euo pipefail

NS_DEMO="${NS_DEMO:-decoupled}"
NS_KARTA="${NS_KARTA:-karta-system}"
RELEASE="${RELEASE:-decoupled}"
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
echo "  ${C_BOLD}|  Karta without KAI (decoupled scheduler)${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  Does Karta require KAI, or can maps work with the cluster"
echo "  |  default scheduler alone?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Karta has no hard dependency on KAI"
note "PyTorchJob pods use empty/default-scheduler — not kai-scheduler"
note "Karta is schema translation; placement stays with kube-scheduler"
note "Training Operator webhook endpoints are ready before helm create"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "GPU topology / secondary scheduling features of KAI"
note "That Karta places pods or replaces the Training Operator"
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
section "1. Install operators (Karta + Training Operator, NO KAI)"
why "Install only what this PoC needs — never KAI."
expect "install-operators.sh finishes; Karta + Training Operator ready."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
else
  info "Uses scripts/install-operators.sh — never installs KAI"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify no KAI + operators up"
why "Fail fast if KAI sneaked in or Training Operator webhooks lack endpoints."
expect "No KAI CRDs; Karta Running; pytorchjobs CRD; Fail webhooks have endpoints."
run bash -c "$OC get crd 2>/dev/null | grep -iE 'kai|gpuscheduling' || echo 'no KAI CRDs — good'"
run "$OC" get pods -n "$NS_KARTA"
run "$OC" get crd pytorchjobs.kubeflow.org
run bash -c "$OC get pods,svc -n kubeflow 2>/dev/null || $OC get deploy -A 2>/dev/null | grep -i training || true"
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
"$OC" get crd pytorchjobs.kubeflow.org >/dev/null 2>&1 \
  || fail "pytorchjobs.kubeflow.org CRD missing — Training Operator install failed?"
# CRD alone is not enough: Fail-policy webhooks need Service endpoints or helm CREATE fails.
info "Checking PyTorchJob validating webhook endpoints (failurePolicy=Fail)..."
webhook_backends="$("$OC" get validatingwebhookconfiguration -o json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    for wh in item.get("webhooks", []):
        if "pytorchjob" not in wh.get("name", "").lower():
            continue
        if wh.get("failurePolicy", "Fail") != "Fail":
            continue
        svc = (wh.get("clientConfig") or {}).get("service") or {}
        ns, sn = svc.get("namespace"), svc.get("name")
        if ns and sn:
            print(f"{ns}/{sn}")
' 2>/dev/null | sort -u || true)"
if [[ -z "${webhook_backends}" ]]; then
  fail "No PyTorchJob Fail webhook found — re-run ./scripts/install-operators.sh"
fi
while IFS= read -r backend; do
  [[ -n "${backend}" ]] || continue
  ns="${backend%%/*}"; svc="${backend#*/}"
  addrs="$("$OC" get endpoints "${svc}" -n "${ns}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [[ -z "${addrs// /}" ]]; then
    fail "Webhook ${backend} has 0 endpoints — helm will fail. Fix: oc get pods,svc,endpoints -n ${ns}; or re-run ./scripts/install-operators.sh"
  fi
  ok "Webhook backend ${backend} has endpoints"
done <<< "${webhook_backends}"
ok "Karta + Training Operator ready; KAI not required"
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies the PyTorchJob Karta map and a sample training Job."
expect "Helm release lands in $NS_DEMO."
# ---------------------------------------------------------------------------
run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory"
why "Confirm map + PyTorchJob exist; wait briefly for Training Operator pods."
expect "karta + pytorchjob listed; at least one pod appears."
# ---------------------------------------------------------------------------
run "$OC" get karta
run "$OC" get pytorchjob -n "$NS_DEMO"
info "Waiting briefly for Training Operator to create pods..."
for i in $(seq 1 20); do
  count="$("$OC" get pods -n "$NS_DEMO" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "attempt ${i}/20  pods=${count}"
  run "$OC" get pods -n "$NS_DEMO" || true
  if [[ "${count}" -ge 1 ]]; then
    break
  fi
  sleep 3
done
ok "Inventory complete"
pause

# ---------------------------------------------------------------------------
section "4. Karta map (translation only)"
why "Inspect the map to show it describes structure — not placement."
expect "kubeflow-org-pytorchjob-v1 YAML with pod template paths."
# ---------------------------------------------------------------------------
run bash -c "$OC get karta kubeflow-org-pytorchjob-v1 -o yaml | head -60"
ok "Map describes PyTorchJob structure — not placement"
pause

# ---------------------------------------------------------------------------
section "5. Scheduler proof — default, not KAI"
why "Empirically prove pods are not bound to kai-scheduler."
expect "schedulerName empty or default-scheduler on all demo pods."
# ---------------------------------------------------------------------------
run bash -c "$OC get pods -n $NS_DEMO -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.schedulerName}{\"\\t\"}{.status.phase}{\"\\n\"}{end}'" || true
if "$OC" get pods -n "$NS_DEMO" -o jsonpath='{range .items[*]}{.spec.schedulerName}{"\n"}{end}' 2>/dev/null | grep -qi kai; then
  warn "Found kai-scheduler on a pod — unexpected for this demo"
else
  ok "No kai-scheduler on demo pods (empty/default-scheduler expected)"
fi
pause

# ---------------------------------------------------------------------------
section "6. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  Decoupled scheduler demo:
    Karta  — schema map for PyTorchJob (optional RayJob via --set)
    Placement — cluster default scheduler
    KAI — not installed, not required

  Useful re-checks:
    $OC get karta kubeflow-org-pytorchjob-v1 -o yaml
    $OC get pytorchjob,pods -n $NS_DEMO
    $OC get pods -n $NS_DEMO -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.schedulerName}{\"\\n\"}{end}'

  Cleanup (optional — not run by this script):
    helm uninstall $RELEASE -n $NS_DEMO
    # helm uninstall karta -n $NS_KARTA

  Re-run without reinstalling operators:
    SKIP_OPERATORS=1 ./scripts/runthrough.sh

  Non-interactive:
    INTERACTIVE=0 ./scripts/runthrough.sh
EOF
ok "Runthrough finished"
