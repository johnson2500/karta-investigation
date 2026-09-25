# Karta Zero-Code Compound CRD Showcase (RayJob)

**Presentation:** open [`presentation/index.html`](presentation/index.html) (speaker notes with `?`). Overview: [`presentation/README.md`](presentation/README.md).

**Hands-on lab:** follow [karta-rayjob-compound-crd-runthrough.md](karta-rayjob-compound-crd-runthrough.md) for a beginner step-by-step deploy (what each step verifies and showcases).

**Verbose script:** from this directory run [`scripts/runthrough.sh`](scripts/runthrough.sh) (prints commands, checks, and pauses). Skip pauses with `INTERACTIVE=0`; skip operator reinstall with `SKIP_OPERATORS=1` (requires Karta and KubeRay already Running — KubeRay may live outside `ray-system`).

Helm chart that deploys a **Karta** map for `ray.io/v1 RayJob` plus a sample RayJob.

This chart does **not** install operators. Install Karta and KubeRay first, then install this chart.

## Jira question answered

**What is Karta adding atop KAI and Grove?**

Karta is a **declarative schema-translation engine**. It tells the platform how to walk a compound CRD (here: RayJob → head + worker pod templates, status, gang groups) **without** writing a dedicated Go controller and **without** changing Grove or KAI.

| Layer | Role in this showcase |
|-------|------------------------|
| **Karta** | YAML + JQ paths: parse RayJob → PodGroup-oriented contracts |
| **KubeRay** | Owns RayJob lifecycle (creates pods) |
| **Grove** (optional) | Clique topologies for other multi-node shapes — not required here |
| **KAI** (optional) | GPU topology placement when present — not required for the map |

```
RayJob CR  -->  KubeRay operator  -->  head/worker pods
     ^
     |  (describes schema only; zero Go)
Karta map (run.ai/v1alpha1)
     |
     v
Platform / EWI reads PodGroup hints + unified status
```

## Objective

Prove to stakeholders that onboarding a new AI framework is a **Karta YAML**, not a new operator fork.

## What this chart builds

1. Cluster-scoped `Karta` for `RayJob` with JQ paths into head/worker templates and status mappings (`Complete` / `Running` / `Failed` + KubeRay phases).
2. A standard `RayJob` manifest for OpenShift (restricted-friendly securityContext by default).

## File guide

| File | What it is |
|------|------------|
| [`Chart.yaml`](Chart.yaml) | Helm chart metadata |
| [`values.yaml`](values.yaml) | Toggles for the Karta map and sample RayJob |
| [`templates/karta-rayjob.yaml`](templates/karta-rayjob.yaml) | `run.ai/v1alpha1 Karta` for RayJob |
| [`templates/rayjob-sample.yaml`](templates/rayjob-sample.yaml) | Sample `ray.io/v1 RayJob` |
| [`templates/_helpers.tpl`](templates/_helpers.tpl) | Shared Helm helpers (fullname, labels) |
| [`templates/NOTES.txt`](templates/NOTES.txt) | Post-install `oc` checks |
| [`scripts/install-operators.sh`](scripts/install-operators.sh) | Installs Karta + KubeRay (not KAI/Grove) |
| [`presentation/`](presentation/) | HTML slideshow (zero-code map, paths, stakeholder talking points) |

## Prerequisites

- OpenShift or Kubernetes cluster
- `helm`, `oc` (or `kubectl`)
- Cluster-admin (or equivalent) for operators and cluster-scoped Karta CRs

## 1. Install operators (OpenShift-oriented)

```bash
./scripts/install-operators.sh
```

Or manually:

```bash
# Karta (schema engine only; chart still at run-ai GHCR)
helm upgrade --install karta oci://ghcr.io/run-ai/karta/karta \
  --version 0.2.0 -n karta-system --create-namespace --wait --timeout 5m \
  --set podSecurityContext.runAsUser=null \
  --set podSecurityContext.runAsGroup=null \
  --set resources.requests.memory=128Mi \
  --set resources.limits.memory=512Mi

# KubeRay Operator
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update
helm upgrade --install kuberay-operator kuberay/kuberay-operator \
  --version 1.3.2 -n ray-system --create-namespace --wait
```

On OpenShift you can also install KubeRay from OperatorHub; the chart only needs the `ray.io` CRDs and operator running. `install-operators.sh` reuses a ready `kuberay-operator` Deployment in any namespace (set `FORCE_KUBERAY_INSTALL=1` to install our release anyway).

Confirm:

```bash
oc get crd rayjobs.ray.io
oc get deploy -n karta-system
oc get deploy -n ray-system
```

## 2. Install this example

From the repo root (`run-ai-karta`):

```bash
helm upgrade --install ray-demo ./examples/karta-rayjob-compound-crd \
  -n ray-demo --create-namespace
```

## 3. Demonstrate zero Go / layer separation

```bash
# The map is pure YAML — no custom controller image for Ray
oc get karta compound-ray-io-rayjob-v1 -o yaml

# Spot the JQ paths that replace hard-coded Go structs
oc get karta compound-ray-io-rayjob-v1 -o jsonpath='{.spec.structureDefinition.childComponents[*].specDefinition.podTemplateSpecPath}{"\n"}'
# .spec.rayClusterSpec.headGroupSpec.template
# .spec.rayClusterSpec.workerGroupSpecs[].template

# Unified statusMappings (Complete / Running / Failed + phases)
oc get karta compound-ray-io-rayjob-v1 -o jsonpath='{.spec.structureDefinition.rootComponent.statusDefinition.statusMappings}' | python3 -m json.tool

# Workload still runs under KubeRay + default-scheduler (or KAI if you add it later)
oc get rayjob -n ray-demo
oc get pods -n ray-demo
oc get pods -n ray-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.schedulerName}{"\n"}{end}'
```

Stakeholder talking points:

1. **Zero Go code** — only a Karta CR; KubeRay is unchanged.
2. **Layer separation** — Karta parses compound RayJob → PodGroup contracts; Grove/KAI remain optional consumers.
3. **Roadmap** — new AI frameworks = new Karta maps, not dedicated Go operators per framework.

## What the chart creates

| Resource | Kind |
|----------|------|
| `compound-ray-io-rayjob-v1` | `Karta` |
| `rayjob-compound-demo` | `RayJob` |

## Uninstall

```bash
./scripts/uninstall.sh
# FORCE=1 ./scripts/uninstall.sh
# KEEP_OPERATORS=0 ./scripts/uninstall.sh   # also remove Karta/KubeRay
```

Or manually:

```bash
helm uninstall ray-demo -n ray-demo
# optional: helm uninstall kuberay-operator -n ray-system
# optional: helm uninstall karta -n karta-system
```

## Roadmap takeaway

Karta eliminates the need for a **dedicated Go operator per AI framework** when the goal is platform visibility, gang hints, and status normalization. Grove and KAI keep doing topology and placement; Karta is the portable contract between compound CRDs and those layers.
