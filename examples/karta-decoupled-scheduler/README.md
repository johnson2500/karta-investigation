# Karta Decoupled Scheduler Showcase

**Presentation:** open [`presentation/index.html`](presentation/index.html) (speaker notes with `?`). Overview: [`presentation/README.md`](presentation/README.md).

**Hands-on lab:** follow [karta-decoupled-scheduler-runthrough.md](karta-decoupled-scheduler-runthrough.md) for a beginner step-by-step deploy (what each step verifies and showcases).

**Verbose script:** from this directory run [`scripts/runthrough.sh`](scripts/runthrough.sh) (prints commands, checks, and pauses). Skip pauses with `INTERACTIVE=0`; skip operator reinstall with `SKIP_OPERATORS=1`.

Helm chart that deploys a **Karta** map for `kubeflow.org/v1 PyTorchJob` (optional RayJob) and a sample workload that binds with the **default kube-scheduler** — **no KAI**.

This chart does **not** install operators. Install Karta (+ Training Operator) first.

## Jira question answered

**Are there any hard dependencies on KAI?**

**No.** Karta is a pure schema-translation controller. It registers declarative maps; pods still schedule through whatever `schedulerName` the workload uses (OpenShift default / kube-scheduler, or vanilla Volcano if you choose). KAI is an optional placement engine, not a runtime requirement for Karta.

```
PyTorchJob / RayJob
        |
   Training / KubeRay operator
        |
   pods (schedulerName unset → default-scheduler)
        ^
        | describes schema only
     Karta map
        |
   EWI / platform (optional consumer of PodGroup hints)
```

## Objective

Prove Red Hat AI can adopt Karta with a **different scheduler** than KAI.

## What this chart builds

1. Docs + script to deploy **Karta** (and Training Operator) on OpenShift **without KAI**.
2. Optional notes for **External Workload Integrator (EWI)** as a Karta consumer (not a scheduler).
3. A compound CRD (`PyTorchJob`, optional `RayJob`) mapped by a Karta spec.
4. Annotations that mirror PodGroup metadata an EWI-style consumer would derive from the map.

## File guide

| File | What it is |
|------|------------|
| [`Chart.yaml`](Chart.yaml) | Helm chart metadata |
| [`values.yaml`](values.yaml) | Karta maps + PyTorchJob / RayJob toggles (`schedulerName` empty by default) |
| [`templates/karta-pytorchjob.yaml`](templates/karta-pytorchjob.yaml) | Karta map for PyTorchJob |
| [`templates/karta-rayjob.yaml`](templates/karta-rayjob.yaml) | Optional Karta map for RayJob |
| [`templates/pytorchjob-sample.yaml`](templates/pytorchjob-sample.yaml) | Sample PyTorchJob on default-scheduler |
| [`templates/_helpers.tpl`](templates/_helpers.tpl) | Shared Helm helpers (fullname, labels) |
| [`templates/NOTES.txt`](templates/NOTES.txt) | Post-install `oc` checks |
| [`templates/rayjob-sample.yaml`](templates/rayjob-sample.yaml) | Optional sample RayJob |
| [`scripts/install-operators.sh`](scripts/install-operators.sh) | Karta + Training Operator; never installs KAI |
| [`presentation/`](presentation/) | HTML slideshow (no hard KAI dep, EWI vs KAI, proof commands) |

## Prerequisites

- OpenShift or Kubernetes cluster
- `helm`, `oc` (or `kubectl`)
- Cluster-admin for operators and cluster-scoped Karta CRs

## 1. Install operators without KAI

```bash
./scripts/install-operators.sh
```

Manual equivalent:

```bash
# Karta — schema engine only (no KAI chart / CRDs pulled in)
# Chart still at run-ai GHCR; dsx-ai-factory/workload-map OCI path is not published yet.
helm upgrade --install karta oci://ghcr.io/run-ai/karta/karta \
  --version 0.2.0 -n karta-system --create-namespace --wait --timeout 5m \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi

# Kubeflow Training Operator (PyTorchJob CRD + controller + validating webhook)
# Prefer ./scripts/install-operators.sh — it reuses OpenShift AI's operator when
# healthy, and always waits for webhook Service endpoints before returning.
oc apply -k "github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.8.1"
oc rollout status deployment/training-operator -n kubeflow --timeout=3m
oc get endpoints training-operator -n kubeflow   # must show an IP before helm
```
### External Workload Integrator (EWI)

EWI is the Run:ai component that **reads Karta maps** and builds hierarchical / PodGroup views for the control plane. Deploy it from your Run:ai platform package when available.

Important for this Jira answer:

- EWI ≠ KAI. EWI consumes schema; KAI (or kube-scheduler / Volcano) places pods.
- This PoC runs **without** EWI and **without** KAI: Karta CR + Training Operator + default-scheduler is enough to show independence.
- Sample workload annotations (`karta.run.ai/podgroup-*`) illustrate the contract EWI would materialize from `optimizationInstructions.gangScheduling.podGroups`.

Confirm KAI is absent:

```bash
oc get crd | grep -iE 'kai|gpuscheduling' || echo "no KAI CRDs — good for this demo"
oc get deploy -A | grep -i kai || echo "no KAI deployments"
```

## 2. Install this example

```bash
helm upgrade --install decoupled ./examples/karta-decoupled-scheduler \
  -n decoupled --create-namespace
```

Optional Ray path (requires KubeRay; still no KAI):

```bash
helm upgrade --install decoupled ./examples/karta-decoupled-scheduler \
  -n decoupled --create-namespace \
  --set karta.rayJob.enabled=true \
  --set rayJob.enabled=true
```

## 3. Inspect generated resources (stakeholder demo)

```bash
# Karta map is present and cluster-scoped
oc get karta
oc get karta kubeflow-org-pytorchjob-v1 -o yaml | head -80

# Compound CRD submitted
oc get pytorchjob -n decoupled
oc get pods -n decoupled -l training.kubeflow.org/job-name=pytorchjob-default-scheduler

# PodGroup-oriented annotations derived from the Karta contract
oc get pytorchjob pytorchjob-default-scheduler -n decoupled -o jsonpath='{.metadata.annotations}' | python3 -m json.tool
oc get pods -n decoupled -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.karta\.run\.ai/component}{"\n"}{end}'

# Default scheduler bound the pods — not kai-scheduler
oc get pods -n decoupled -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.schedulerName}{"\t"}{.status.phase}{"\n"}{end}'
# Expect empty or "default-scheduler" — never kai-scheduler
```

Optional vanilla Volcano (still not KAI): set `pytorchJob.schedulerName=volcano` after installing Volcano separately.

## What the chart creates

| Resource | Kind |
|----------|------|
| `kubeflow-org-pytorchjob-v1` | `Karta` |
| `pytorchjob-default-scheduler` | `PyTorchJob` |
| (optional) `decoupled-ray-io-rayjob-v1` | `Karta` |
| (optional) `rayjob-default-scheduler` | `RayJob` |

## Uninstall

```bash
./scripts/uninstall.sh
# FORCE=1 ./scripts/uninstall.sh
# KEEP_OPERATORS=0 ./scripts/uninstall.sh   # also remove Karta (Training Operator left alone)
```

Or manually:

```bash
helm uninstall decoupled -n decoupled
# optional: helm uninstall karta -n karta-system
```

## Roadmap takeaway

**RH AI can adopt Karta with a different scheduler.** Karta’s runtime contract is the map CR; placement stays pluggable (OpenShift default-scheduler, vanilla Volcano, or KAI later). There is no hard dependency on KAI for schema translation or workload submission.
