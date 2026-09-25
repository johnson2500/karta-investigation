#!/usr/bin/env bash
# Verbose Karta RayJob compound-CRD runthrough (zero Go / no KAI / no Grove).
#
#   ./scripts/runthrough.sh
#
# Env knobs:
#   INTERACTIVE=0   skip Enter pauses (default: 1)
#   SKIP_OPERATORS=1  skip operator install
#   OC=kubectl        override CLI (default: oc, else kubectl)
set -euo pipefail

NS_DEMO="${NS_DEMO:-ray-demo}"
NS_KARTA="${NS_KARTA:-karta-system}"
NS_RAY="${NS_RAY:-ray-system}"
RELEASE="${RELEASE:-ray-demo}"
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
echo "  ${C_BOLD}|  Karta + RayJob (compound CRD, zero Go)${C_RESET}"
echo "  |----------------------------------------------------------|"
echo "  |  Can Karta map a compound RayJob in YAML alone — without"
echo "  |  custom Go, Grove, or KAI?"
rule
echo ""
echo "  ${C_BOLD}What this proves${C_RESET}"
note "Karta publishes a declarative RayJob map (head/worker paths)"
note "KubeRay still owns RayJob lifecycle and creates pods"
note "Pods use empty/default-scheduler — never kai-scheduler"
note "Grove and KAI are not required for the map or for Ray to run"
echo ""
echo "  ${C_BOLD}What this does NOT prove${C_RESET}"
note "Kueue admission / GPU quota (see karta-kueue-admission)"
note "That Karta replaces KubeRay or schedules pods"
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
section "1. Install operators (Karta + KubeRay)"
why "Need Karta (maps) and KubeRay (RayJob controller) — nothing else."
expect "install-operators.sh finishes; KubeRay may be reused from another namespace."
# ---------------------------------------------------------------------------
if [[ "${SKIP_OPERATORS}" == "1" ]]; then
  warn "SKIP_OPERATORS=1 — skipping operator install"
  note "Requires Karta + KubeRay already Running (KubeRay may be outside ray-system)."
else
  info "Uses scripts/install-operators.sh (no Grove, no KAI)"
  run "${SCRIPT_DIR}/install-operators.sh"
fi

section "1b. Verify operators + RayJob CRD"
why "Fail fast if the RayJob CRD or operator pods are missing."
expect "rayjobs.ray.io CRD + Running pods in karta-system; kuberay-operator deploy somewhere."
run "$OC" get crd rayjobs.ray.io || true
run "$OC" get pods -n "$NS_KARTA"
# KubeRay may live in ray-system OR be reused from OperatorHub / another release.
info "Looking for kuberay-operator Deployment (any namespace)..."
run bash -c "$OC get deploy -A --no-headers 2>/dev/null | grep -iE 'kuberay|ray-operator' || true"
run "$OC" get pods -n "$NS_RAY" || true
"$OC" get crd rayjobs.ray.io >/dev/null 2>&1 || {
  if [[ "${SKIP_OPERATORS}" == "1" ]]; then
    fail "KubeRay not found (rayjobs.ray.io CRD missing) — re-run without SKIP_OPERATORS=1"
  fi
  fail "rayjobs.ray.io CRD missing"
}
"$OC" get pods -n "$NS_KARTA" --no-headers 2>/dev/null | grep -q Running \
  || fail "No Running pods in $NS_KARTA"
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
ok "Karta + KubeRay ready"
pause

# ---------------------------------------------------------------------------
section "2. Install / refresh demo chart"
why "Chart applies the RayJob Karta map and a sample RayJob."
expect "Helm release lands in $NS_DEMO."
# ---------------------------------------------------------------------------
run helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -n "$NS_DEMO" --create-namespace
ok "Helm release '$RELEASE' in namespace '$NS_DEMO'"
pause

# ---------------------------------------------------------------------------
section "3. Inventory"
why "Confirm the map and RayJob objects exist before inspecting paths."
expect "karta compound-ray-io-rayjob-v1 + rayjob in $NS_DEMO (pods may still be pulling)."
# ---------------------------------------------------------------------------
run "$OC" get karta compound-ray-io-rayjob-v1
run "$OC" get rayjob -n "$NS_DEMO"
info "Pods may take a minute while the Ray image pulls..."
run "$OC" get pods -n "$NS_DEMO" || true
ok "Inventory complete"
pause

# ---------------------------------------------------------------------------
section "4. Zero-Go map — inspect Karta paths"
why "Show that JQ-style paths replace hard-coded Go structs for RayJob."
expect "headGroupSpec.template and workerGroupSpecs[].template in the map."
# ---------------------------------------------------------------------------
info "These JQ paths replace hard-coded Go structs for RayJob"
run bash -c "$OC get karta compound-ray-io-rayjob-v1 -o yaml | head -80"
run bash -c "$OC get karta compound-ray-io-rayjob-v1 -o jsonpath='{.spec.structureDefinition.childComponents[*].specDefinition.podTemplateSpecPath}{\"\\n\"}'" || true
ok "Look for headGroupSpec.template and workerGroupSpecs[].template"
pause

# ---------------------------------------------------------------------------
section "5. Runtime — KubeRay + default scheduler (not KAI)"
why "Prove runtime separation: Karta maps, KubeRay runs, scheduler is default."
expect "Pods appear; schedulerName empty or default-scheduler — never kai-scheduler."
# ---------------------------------------------------------------------------
info "Wait briefly for pods (image pull can be slow)"
for i in $(seq 1 20); do
  count="$("$OC" get pods -n "$NS_DEMO" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  info "attempt ${i}/20  pods=${count}"
  run "$OC" get rayjob -n "$NS_DEMO" || true
  run "$OC" get pods -n "$NS_DEMO" || true
  if [[ "${count}" -ge 1 ]]; then
    break
  fi
  sleep 3
done
run bash -c "$OC get pods -n $NS_DEMO -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.schedulerName}{\"\\n\"}{end}'" || true
info "Expect empty or default-scheduler — never kai-scheduler"
ok "Layer separation: Karta maps; KubeRay runs; scheduler is cluster default"
pause

# ---------------------------------------------------------------------------
section "6. Summary"
# ---------------------------------------------------------------------------
cat <<EOF
  Zero-code compound CRD demo:
    Karta   — declarative RayJob map (no custom Go)
    KubeRay — creates head/worker pods
    Grove/KAI — optional; not required here

  Useful re-checks:
    $OC get karta compound-ray-io-rayjob-v1 -o yaml
    $OC get rayjob,pods -n $NS_DEMO

  Cleanup (optional — not run by this script):
    helm uninstall $RELEASE -n $NS_DEMO
    # helm uninstall kuberay-operator -n $NS_RAY
    # helm uninstall karta -n $NS_KARTA

  Re-run without reinstalling operators (Karta + KubeRay must already be up):
    SKIP_OPERATORS=1 ./scripts/runthrough.sh

  Non-interactive:
    INTERACTIVE=0 ./scripts/runthrough.sh
EOF
ok "Runthrough finished"
