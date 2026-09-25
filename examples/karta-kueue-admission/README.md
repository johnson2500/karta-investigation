# Karta + Kueue Multi-Layer Admission Showcase

**Presentation:** open [`presentation/index.html`](presentation/index.html) (speaker notes with `?`). Overview: [`presentation/README.md`](presentation/README.md).

**Hands-on lab:** follow [karta-kueue-admission-runthrough.md](karta-kueue-admission-runthrough.md) for a beginner step-by-step deploy (what each step verifies and showcases).

**Verbose script:** from this directory run [`scripts/runthrough.sh`](scripts/runthrough.sh) (prints commands, checks, and pauses). Skip pauses with `INTERACTIVE=0`; skip operator reinstall with `SKIP_OPERATORS=1` (requires Karta, KubeRay, and Kueue already Running — KubeRay may live outside `ray-system`).

Focused Helm chart for the **three-layer** stack on OpenShift:

1. **Kueue** — admission & GPU quotas  
2. **Karta** — CRD → PodGroup translation  
3. **kube-scheduler / KAI** — placement  

Distinct from [`../karta-grove-kueue`](../karta-grove-kueue) (Grove + batch Job). This showcase is **RayJob + strict GPU queuing**.

This chart does **not** install operators. Install Karta, KubeRay, and Kueue first.

## Jira questions answered

- **Can it work with Kueue?** — Yes. RayJobs labeled `kueue.x-k8s.io/queue-name` are admitted against a ClusterQueue; Karta maps the compound CRD independently.
- **How does it fit into the RH AI Roadmap?** — Aligns with WG WAS / **KEP-6012 CompositePodGroup**: Karta’s `optimizationInstructions.gangScheduling.podGroups` is the portable PodGroup hierarchy that admission (Kueue) and placement (scheduler/KAI) can share.

```
Step 1  Admission     Kueue LocalQueue / ClusterQueue (GPU quota)
Step 2  Translation   Karta map → head/worker paths + PodGroup hints
Step 3  Placement     default-scheduler or KAI binds admitted pods
```

## Objective

Show stakeholders that exceeding GPU quota leaves a Workload **Pending** (queued), while the admitted RayJob proceeds through Karta-described structure into placement — without a custom Ray↔Kueue Go bridge.

## What this chart builds

1. Kueue `ResourceFlavor`, `ClusterQueue` (strict `nvidia.com/gpu: "1"`), and `LocalQueue`.
2. Karta map for `ray.io/v1 RayJob`.
3. Two suspended RayJobs on the same queue, each requesting 1 GPU → second intentionally exceeds quota.

## File guide

| File | What it is |
|------|------------|
| [`Chart.yaml`](Chart.yaml) | Helm chart metadata |
| [`values.yaml`](values.yaml) | GPU quota + two RayJobs |
| [`templates/karta-rayjob.yaml`](templates/karta-rayjob.yaml) | Karta map (Layer 2) |
| [`templates/kueue-*.yaml`](templates/) | Flavor, ClusterQueue, LocalQueue (Layer 1) |
| [`templates/rayjob-sample.yaml`](templates/rayjob-sample.yaml) | Two queue-labeled RayJobs |
| [`templates/_helpers.tpl`](templates/_helpers.tpl) | Shared Helm helpers (fullname, labels) |
| [`templates/NOTES.txt`](templates/NOTES.txt) | Post-install `oc` checks |
| [`scripts/install-operators.sh`](scripts/install-operators.sh) | Karta + KubeRay + Kueue (RayJob integration) |
| [`scripts/kueue-values.yaml`](scripts/kueue-values.yaml) | Enables `ray.io/rayjob` in Kueue |
| [`presentation/`](presentation/) | HTML slideshow (admit vs queue, three layers, KEP-6012) |

## Prerequisites

- OpenShift or Kubernetes cluster (`oc` / `kubectl`, `helm`)
- Cluster-admin for operators and cluster-scoped CRs
- GPU nodes optional: queuing is demonstrated via **quota**, even if nodes lack GPUs (Workloads still Pending/Admitted by Kueue). Pods may stay Pending at Layer 3 without real GPUs — that still proves admission vs placement separation.

## 1. Install operators

```bash
./scripts/install-operators.sh
```

Or manually:

```bash
helm upgrade --install karta oci://ghcr.io/run-ai/karta/karta \
  --version 0.2.0 -n karta-system --create-namespace --wait --timeout 5m \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi

helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm upgrade --install kuberay-operator kuberay/kuberay-operator \
  --version 1.3.2 -n ray-system --create-namespace --wait

# Or reuse an existing KubeRay (OperatorHub / another namespace). install-operators.sh
# skips helm when a ready kuberay-operator Deployment already exists cluster-wide.
# FORCE_KUBERAY_INSTALL=1 forces a local release anyway.

# Kueue with RayJob framework enabled (see scripts/kueue-values.yaml)
helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version 0.19.5 -n kueue-system --create-namespace --wait \
  -f ./examples/karta-kueue-admission/scripts/kueue-values.yaml
```

## 2. Install this example

```bash
helm upgrade --install admit ./examples/karta-kueue-admission \
  -n admit --create-namespace
```

## 3. Stakeholder walkthrough

### Step 1 — Admission (Pending vs Admitted)

```bash
oc get clusterqueue gpu-cluster-queue -o yaml | python3 -c "
import sys,yaml
cq=yaml.safe_load(sys.stdin)
print('GPU nominalQuota:', cq['spec']['resourceGroups'][0]['flavors'][0]['resources'])
"

oc get localqueue -n admit
oc get workloads -n admit
# Expect one Admitted (or QuotaReserved) and one Pending — GPU quota is 1, both jobs ask for 1.

oc get rayjob -n admit
# Suspended until admitted; second stays suspended while first holds quota.
```

### Step 2 — Translation (PodGroup hierarchy)

```bash
oc get karta admit-ray-io-rayjob-v1 -o yaml
# Child JQ paths + gangScheduling.podGroups (CompositePodGroup-shaped contract)

oc get rayjob -n admit -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.kueue\.x-k8s\.io/queue-name}{"\t"}{.metadata.annotations.karta\.run\.ai/podgroup-name}{"\n"}{end}'
```

### Step 3 — Placement

```bash
# After admission, KubeRay creates pods; scheduler (default or KAI) binds them.
oc get pods -n admit -o wide
oc get pods -n admit -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.schedulerName}{"\t"}{.status.phase}{"\n"}{end}'
```

Release quota to admit the queued job:

```bash
oc delete rayjob rayjob-gpu-admit -n admit
oc get workloads -n admit -w
```

## What the chart creates

| Resource | Kind |
|----------|------|
| `admit-ray-io-rayjob-v1` | `Karta` |
| `gpu-flavor` | `ResourceFlavor` |
| `gpu-cluster-queue` | `ClusterQueue` (`nvidia.com/gpu: 1`) |
| `gpu-local-queue` | `LocalQueue` |
| `rayjob-gpu-admit` | `RayJob` (1 GPU) |
| `rayjob-gpu-queued` | `RayJob` (1 GPU → queued) |

## Uninstall

```bash
./scripts/uninstall.sh
# FORCE=1 ./scripts/uninstall.sh
# KEEP_OPERATORS=0 ./scripts/uninstall.sh   # also remove Karta/KubeRay/Kueue
```

Or manually:

```bash
helm uninstall admit -n admit
# optional: helm uninstall kueue -n kueue-system
# optional: helm uninstall kuberay-operator -n ray-system
# optional: helm uninstall karta -n karta-system
```

## Roadmap takeaway

Karta + Kueue match the RH AI direction: **admission (quotas) stays in Kueue**, **schema translation stays in Karta**, **placement stays pluggable** (kube-scheduler or KAI). The PodGroup hints in the Karta map track **WG WAS / KEP-6012 CompositePodGroup** so compound AI workloads share one hierarchy language across layers.
