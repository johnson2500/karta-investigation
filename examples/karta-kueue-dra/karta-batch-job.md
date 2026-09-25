# Karta map for `batch/v1` Job

This document walks through [`templates/karta-batch-job.yaml`](templates/karta-batch-job.yaml) — the **Layer 2** object in the karta-kueue-dra demo.

After `helm install`, the chart creates a cluster object roughly named `dra-batch-job-v1` (see `karta.batchJob.name` in [`values.yaml`](values.yaml)):

```yaml
apiVersion: run.ai/v1alpha1
kind: Karta
metadata:
  name: dra-batch-job-v1
```

**What this CR is:** a declarative **map** that teaches platforms how to read a normal Kubernetes `Job` — where pods live, where DRA GPU claims live, how status maps to phases, how suspend/resume works, and how pods group for gang-style views.

**What this CR is not:**

| Not this | Who owns that instead |
|----------|------------------------|
| A scheduler | kube-scheduler (or optional KAI) |
| A queue / admission controller | Kueue |
| A GPU allocator | DRA + device driver |
| A Grove clique topology | Grove (separate project) |

One-line takeaway: **Karta translates schema; it does not decide who runs or which GPU binds.**

---

## How it fits this demo

```
batch/v1 Job  (sample-job.yaml)
      │
      ├──► Kueue     — admit / queue via LocalQueue + example.com/gpu quota
      ├──► DRA       — ResourceClaimTemplate on the pod template
      └──► Karta     — this map: “here’s how to interpret that Job”
```

Inspect the live object:

```bash
oc get karta dra-batch-job-v1 -o yaml
```

---

## Top-level shape

| Field | Role |
|-------|------|
| `spec.structureDefinition` | **Where things are** in the Job YAML (paths into pods, claims, status, suspend) |
| `spec.optimizationInstructions` | **Scheduling intent hints** (how to group pods for gang / co-scheduling views) |

Consumers (controllers, platforms, tools) read these paths with JQ-style expressions instead of shipping custom Go for every CRD.

---

## 1. `structureDefinition.rootComponent`

```yaml
rootComponent:
  name: job
  kind:
    group: batch
    version: v1
    kind: Job
```

| Piece | Meaning |
|-------|---------|
| `name: job` | Logical component name used later (status, gang members, etc.) |
| `kind` | This map applies to API `batch/v1` `Job` — not RayJob, not Grove, not a custom trainer |

When a platform sees a Job, it looks up a Karta whose `kind` matches and then follows the paths below.

---

## 2. `specDefinition` — where the pod lives

```yaml
specDefinition:
  podTemplateSpecPath: .spec.template
  fragmentedPodSpecDefinition:
    resourceClaimsPath: .spec.template.spec.resourceClaims
    containersPath: .spec.template.spec.containers
    schedulerNamePath: .spec.template.spec.schedulerName
    labelsPath: .spec.template.metadata.labels
    annotationsPath: .spec.template.metadata.annotations
```

| Path | Points at | Why it matters in this demo |
|------|-----------|-----------------------------|
| `podTemplateSpecPath` | `.spec.template` | Full Pod template Kubernetes uses to create Job pods |
| `resourceClaimsPath` | `.spec.template.spec.resourceClaims` | **DRA**: where GPU claims are declared (not `nvidia.com/gpu: 1`) |
| `containersPath` | `.spec.template.spec.containers` | Containers that may reference those claims via `resources.claims` |
| `schedulerNamePath` | `.spec.template.spec.schedulerName` | Optional custom scheduler; this demo leaves default |
| `labelsPath` / `annotationsPath` | Pod template metadata | Labels/annotations platforms may copy or correlate |

The sample Jobs in [`templates/sample-job.yaml`](templates/sample-job.yaml) put DRA claims exactly where this map says:

```yaml
spec:
  template:
    spec:
      resourceClaims:
        - name: gpu
          resourceClaimTemplateName: single-gpu
```

Without `resourceClaimsPath`, a generic platform would not know Jobs carry DRA claims at that location.

---

## 3. `scaleDefinition` — how many pods

```yaml
scaleDefinition:
  replicasPath: .spec.parallelism // 1
```

| Piece | Meaning |
|-------|---------|
| `.spec.parallelism` | Job field for concurrent pods |
| `// 1` | JQ-style default: if unset, treat as **1** (single-pod Job) |

This demo’s sample Jobs are single-pod; the path still documents how multi-pod Jobs would scale.

---

## 4. `statusDefinition` — portable lifecycle

### Condition field layout

```yaml
statusDefinition:
  conditionsDefinition:
    path: .status.conditions
    typeFieldName: type
    statusFieldName: status
    messageFieldName: message
    reasonFieldName: reason
```

Tells consumers: Job status uses the usual Kubernetes condition array shape (`type` / `status` / …).

### `statusMappings` — Job → portable phases

| Portable phase | How this map detects it |
|----------------|-------------------------|
| `initializing` | `active > 0` and `ready == 0` |
| `running` | `active > 0` and `ready > 0` |
| `completed` | condition `Complete` or `SuccessCriteriaMet` is `True` |
| `failed` | condition `Failed` or `FailureTarget` is `True` |
| `suspended` | condition `Suspended` is `True` |

`suspended` matters for Kueue: Jobs start with `spec.suspend: true` and stay suspended until quota admits them. Platforms reading this map see the same lifecycle language they’d use for other CRDs.

---

## 5. `suspendDefinition` — hold / release pods

```yaml
suspendDefinition:
  suspendActions:
    - path: .spec.suspend
      value: "true"
  resumeActions:
    - path: .spec.suspend
      value: "false"
```

| Action | Field | Effect on a Job |
|--------|-------|-----------------|
| Suspend | `.spec.suspend = true` | Do not create pods yet |
| Resume | `.spec.suspend = false` | Job may create pods |

**Same field Kueue uses.** Karta does not flip suspend itself in this demo; it documents *which* field controllers should toggle if they need a portable suspend/resume contract.

---

## 6. `optimizationInstructions` — gang / grouping hint

```yaml
optimizationInstructions:
  gangScheduling:
    podGroups:
      - name: job
        members:
          - componentName: job
            groupByKeyPaths:
              - .metadata.labels["batch.kubernetes.io/job-name"]
```

| Piece | Meaning |
|-------|---------|
| `podGroups[].name` | Logical group name (`job`) |
| `componentName: job` | Refers to `rootComponent.name` |
| `groupByKeyPaths` | Pods that share this label value belong together |

Kubernetes sets `batch.kubernetes.io/job-name` on pods created by a Job. So:

- All pods from `dra-job-admit` share one group key
- All pods from `dra-job-queued` share another

**What this does:** publishes a **co-scheduling / PodGroup-like view** for consumers (historically useful for KAI-style gang placement).

**What this does not do alone:** it does not run a gang scheduler. Something downstream must consume the hint. In this demo (Kueue + default kube-scheduler + DRA), it is primarily the **portable grouping contract**, not an active placement engine.

---

## Section map (quick reference)

```
Karta dra-batch-job-v1
│
├── structureDefinition          ← “how to read the Job”
│   └── rootComponent (batch/v1 Job)
│       ├── specDefinition       ← pods + DRA claims + labels
│       ├── scaleDefinition      ← parallelism
│       ├── statusDefinition     ← conditions → phases
│       └── suspendDefinition    ← .spec.suspend true/false
│
└── optimizationInstructions     ← “how to group for gang views”
    └── gangScheduling.podGroups
        └── groupBy job-name label
```

---

## Toggle / naming

| Knob | Location | Default |
|------|----------|---------|
| Enable this map | `karta.enabled` + `karta.batchJob.enabled` | `true` |
| Object name | `karta.batchJob.name` | `dra-batch-job-v1` |

Helm renders nothing if either enable flag is false.

---

## Related files

| File | Relationship |
|------|----------------|
| [`templates/sample-job.yaml`](templates/sample-job.yaml) | Jobs this map describes (queue label, suspend, DRA claims) |
| [`templates/dra-resourceclaimtemplate.yaml`](templates/dra-resourceclaimtemplate.yaml) | Template referenced by `resourceClaims` |
| [`README.md`](README.md) | Full glossary, three-layer model, ticket answers |
| [`karta-kueue-dra-runthrough.md`](karta-kueue-dra-runthrough.md) | Step 8: `oc get karta dra-batch-job-v1 -o yaml` |
| Sibling [`../karta-grove-kueue`](../karta-grove-kueue) | Same Job map pattern adapted from that chart |
