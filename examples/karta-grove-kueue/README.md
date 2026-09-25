# Karta + Grove + Kueue (simple example)

**Presentation:** open [`presentation/index.html`](presentation/index.html) (speaker notes with `?`). Overview: [`presentation/README.md`](presentation/README.md).

**Hands-on lab:** follow [karta-grove-kueue-runthrough.md](karta-grove-kueue-runthrough.md) for a beginner step-by-step deploy (what each step verifies and showcases).

**Verbose script:** from this directory run [`scripts/runthrough.sh`](scripts/runthrough.sh) (prints commands, checks, and pauses). Skip pauses with `INTERACTIVE=0`; skip operator reinstall with `SKIP_OPERATORS=1`.

Minimal Helm chart that deploys sample CRs so you can see **Karta**, **Grove**, and **Kueue** on one cluster.

This chart does **not** install the operators. Install those first, then install this chart.

## Roles

| Piece | Role |
|-------|------|
| **Karta** | Cluster-scoped maps: Grove `PodCliqueSet` **and** `batch/v1 Job` (the Job API OpenShift uses for batch work) |
| **Grove** | Multinode orchestrator; this example creates a tiny `PodCliqueSet` (busybox workers) |
| **Kueue** | Cluster queueing; admits multiple sample Jobs through one LocalQueue |

Grove runs on `default-scheduler` here. Native Grove→Kueue scheduler backend support is out of scope for this example.

```
Karta (PodCliqueSet)  -.-> maps -.->  Grove PodCliqueSet  -->  pods
Karta (batch Job)     -.-> maps -.->  kueue-demo-job      -->  admitted by Kueue
                          └── maps -.->  openshift-batch-job -->  admitted by Kueue
```

One Karta definition covers every `batch/v1 Job` — including the OpenShift-styled sample. Platforms do not need a separate map per Job name or OpenShift label set.

## How the files work together

1. **`scripts/install-operators.sh`** (+ **`scripts/grove-values.yaml`**) installs the three controllers cluster-wide.
2. **`helm install`** of this chart renders **`templates/`** using **`values.yaml`**.
3. At runtime:
   - **Karta** CRs tell any Karta-aware tool how to read a Grove `PodCliqueSet` and how to read `batch/v1 Job`s.
   - The **Grove** operator watches the `PodCliqueSet` and creates pods.
   - **Kueue** watches each sample Job (via the LocalQueue label), creates a Workload, and admits it against the ClusterQueue quota.

The PodCliqueSet path and the Job path are independent (no Grove→Kueue wiring). The two Jobs share one queue and one Job Karta.

## Sample Jobs

| Job | Purpose |
|-----|---------|
| `kueue-demo-job` | Generic Kubernetes batch Job |
| `openshift-batch-job` | Same `batch/v1` API with OpenShift-style labels (`app.openshift.io/runtime`) and restricted-v2–friendly `securityContext` |

Both are suspended until Kueue admits them. Toggle or add more under `kueue.sampleJobs` in [`values.yaml`](values.yaml).

## File guide

| File | What it is |
|------|------------|
| [`Chart.yaml`](Chart.yaml) | Helm chart metadata (`name`, `version`). No operator dependencies. |
| [`values.yaml`](values.yaml) | Knobs: Karta maps, Grove PCS, Kueue queues, and the list of sample Jobs. |
| [`templates/_helpers.tpl`](templates/_helpers.tpl) | Shared Helm helpers (fullname, labels) used by every template. |
| [`templates/karta-podcliqueset.yaml`](templates/karta-podcliqueset.yaml) | Karta map for Grove `PodCliqueSet`. |
| [`templates/karta-batch-job.yaml`](templates/karta-batch-job.yaml) | Karta map for `batch/v1 Job` (covers both sample Jobs / OpenShift batch). |
| [`templates/grove-podcliqueset.yaml`](templates/grove-podcliqueset.yaml) | Minimal Grove `PodCliqueSet` (1 replica, 1 worker clique, 2 busybox pods). |
| [`templates/kueue-resourceflavor.yaml`](templates/kueue-resourceflavor.yaml) | Empty `ResourceFlavor` (`grove-kueue-flavor`). |
| [`templates/kueue-clusterqueue.yaml`](templates/kueue-clusterqueue.yaml) | Cluster-wide quota pool. |
| [`templates/kueue-localqueue.yaml`](templates/kueue-localqueue.yaml) | Namespace queue; Jobs target this name. |
| [`templates/kueue-sample-job.yaml`](templates/kueue-sample-job.yaml) | Renders every enabled entry in `kueue.sampleJobs`. |
| [`templates/NOTES.txt`](templates/NOTES.txt) | Printed after `helm install` — quick `kubectl` checks. |
| [`scripts/install-operators.sh`](scripts/install-operators.sh) | Prerequisite: helm-installs Karta, Grove, and Kueue operators. |
| [`scripts/grove-values.yaml`](scripts/grove-values.yaml) | Grove operator config: only `default-scheduler`. |
| [`presentation/`](presentation/) | HTML slideshow (coexistence roles, maps, install/verify). |

## Prerequisites

- A Kubernetes or OpenShift cluster
- `helm` and `kubectl` (or `oc`)
- Cluster-admin (or equivalent) to install operators and cluster-scoped CRs

## 1. Install operators

```bash
./scripts/install-operators.sh
```

Or install manually (versions match the script defaults):

```bash
# Karta (chart still at run-ai GHCR; dsx-ai-factory/workload-map OCI not published yet)
helm upgrade --install karta oci://ghcr.io/run-ai/karta/karta \
  --version 0.2.0 -n karta-system --create-namespace --wait --timeout 5m \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi

# Grove (default-scheduler only — avoids crash if volcano/kai CRDs are absent)
helm upgrade --install grove-operator oci://ghcr.io/ai-dynamo/grove/grove-charts \
  --version v0.1.0-alpha.10-rc1 -n grove-system --create-namespace --wait \
  -f scripts/grove-values.yaml

# Kueue
helm upgrade --install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version 0.19.5 -n kueue-system --create-namespace --wait
```

Override pins with `KARTA_CHART`, `KARTA_VERSION`, `GROVE_VERSION`, or `KUEUE_VERSION` when using the script.

## 2. Install this example

From the repo root (`run-ai-karta`):

```bash
helm upgrade --install demo ./examples/karta-grove-kueue \
  -n demo --create-namespace
```

## 3. Verify

```bash
# Both Karta maps
kubectl get karta
# grove-kueue-podcliqueset-v1alpha1   (Grove)
# grove-kueue-batch-job-v1                    (Jobs, including OpenShift-style)

# Grove workload and pods
kubectl get podcliqueset -n demo
kubectl get pods -n demo

# Kueue admission for both sample Jobs
kubectl get clusterqueue demo-cluster-queue
kubectl get localqueue -n demo
kubectl get workloads -n demo
kubectl get jobs -n demo
```

Expect: Grove pods Running; Workloads for `kueue-demo-job` and `openshift-batch-job` Admitted; Jobs unsuspend and complete.

## What the chart creates

| Resource | Kind |
|----------|------|
| `grove-kueue-podcliqueset-v1alpha1` | `Karta` |
| `grove-kueue-batch-job-v1` | `Karta` |
| `grove-demo` | `PodCliqueSet` |
| `grove-kueue-flavor` | `ResourceFlavor` |
| `demo-cluster-queue` | `ClusterQueue` |
| `demo-queue` | `LocalQueue` |
| `kueue-demo-job` | `Job` |
| `openshift-batch-job` | `Job` |

Toggles and names live in [`values.yaml`](values.yaml).

## Uninstall

```bash
./scripts/uninstall.sh
# FORCE=1 ./scripts/uninstall.sh              # skip confirmation
# KEEP_OPERATORS=0 ./scripts/uninstall.sh     # also remove Karta/Grove/Kueue
```

Or manually:

```bash
helm uninstall demo -n demo
# operators (optional):
# helm uninstall karta -n karta-system
# helm uninstall grove-operator -n grove-system
# helm uninstall kueue -n kueue-system
```
