# Work Around: Fractional GPU Allocation and Utilization

One of the main benefits of Run:ai is that you can utilize and schedule **fractions of a GPU**. There is not really a native kube way to do this with the same dynamic VRAM / swap model, but on OpenShift there are **three main paths**.

This document pairs with the [`karta-openshift-workload-api`](.) example (Karta + Grove + Workload API, **no KAI**). Opt-in Helm samples live in [`templates/fractional-gpu-samples.yaml`](templates/fractional-gpu-samples.yaml).

---

## 1) The Native OpenShift Way: Time-Slicing

[NVIDIA docs — Time-Slicing GPUs in OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/time-slicing-gpus-in-openshift.html)

The most common way to achieve fractional utilization on NVIDIA hardware is **Time-Slicing**.

Through the `ClusterPolicy` of the NVIDIA GPU Operator, you define a fixed number of logical **replicas** for a single physical GPU. For example, if you set `replicas: 4`, a single physical GPU is exposed to the OpenShift scheduler as 4 distinct allocatable resources.

**Example Workload Pod Spec:**  
When developers want a “fraction” (in this case, 25% of the card’s compute time), they request 1 replica:

```yaml
spec:
  containers:
  - name: ml-inference
    image: my-llm-server:latest
    resources:
      limits:
        nvidia.com/gpu: "1"  # 1 out of the 4 defined time-slices
```

Enable the chart’s sample ConfigMap / ClusterPolicy fragment + inference Pod:

```bash
helm upgrade --install demo ./examples/karta-openshift-workload-api \
  -n demo --reuse-values \
  --set fractionalGpu.timeSlicing.enabled=true \
  --set fractionalGpu.timeSlicing.replicas=4 \
  --set fractionalGpu.inferencePod.enabled=true
```

> [!NOTE]
> Unlike Run:ai, native time-slicing does **not** enforce strict memory limits out of the box. If one pod leaks VRAM, it can OOM and impact other pods sharing that physical GPU.

**Best for:** lightweight model inference, interactive notebooks, bursty shared GPU nodes.

---

## 2) The Strict Isolation Way: MIG (Multi-Instance GPU)

[Background — fractional GPUs (MIG vs time-slicing)](https://rafay.co/ai-and-cloud-native-blog/demystifying-fractional-gpus-in-kubernetes-mig-time-slicing-and-custom-schedulers)

If you need hard boundary isolation closer to Run:ai’s virtual memory spaces, use **MIG** on supported cards (A100, H100, and similar). MIG splits the physical silicon into independent hardware instances.

OpenShift / GPU Operator lets you define profiles so developers request them as distinct resources, for example:

```yaml
resources:
  limits:
    nvidia.com/mig-1g.20gb: "1"  # 1 isolated instance (~20GB VRAM profile)
```

Exact resource names depend on the MIG profile configured on the node (`nvidia.com/mig-<profile>`).

> [!NOTE]
> MIG profile changes typically require draining / resetting the GPU. You get strong isolation, not Run:ai-style dynamic re-fractioning without disruption.

**Best for:** multi-tenant inference or training where noisy-neighbor VRAM risk is unacceptable.

---

## 3) Dynamic GPU Slicing

[Red Hat Developers — Benefits of dynamic GPU slicing on OpenShift](https://developers.redhat.com/articles/2025/05/06/benefits-dynamic-gpu-slicing-openshift)

Red Hat’s **Dynamic Accelerator Slicer** addresses static slicing limitations. The operator hooks into Kubernetes **scheduling gates** to provision and deallocate specific GPU slices on demand as pods cycle through the cluster, which reduces idle silicon compared with fixed time-slice replicas.

Use this when time-slicing’s static `replicas: N` wastes capacity or MIG’s profile churn is too heavy for your churn rate.

**Best for:** mixed workloads where slice size should follow demand rather than a fixed ClusterPolicy replica count.

---

## How this fits the OpenShift AI stack (no KAI)

| Concern | Owner on this path |
|---------|--------------------|
| “What fraction / device shape?” | GPU Operator time-slicing, MIG, or Dynamic Accelerator Slicer (+ optional DRA) |
| “May this job start under quota?” | **Kueue** (`nvidia.com/gpu` or DRA-mapped logical quota) |
| “Where do pods / claims live on the CRD?” | **Karta** |
| “How are multi-pod apps shaped?” | **Grove** |
| “Gang / all-or-nothing placement?” | **Workload API** + kube-scheduler |

Run:ai still leads on **dynamic fractional VRAM + host memory swap**. The three OpenShift paths above close most sharing needs without a secondary KAI binary; they do not fully reproduce Run:ai’s virtualization model.

---

## Choosing a path

| Workload | Prefer |
|----------|--------|
| Lightweight inference / demos | Time-slicing |
| Heavy training needing isolation | MIG (supported GPUs) |
| Churny multi-tenant slices | Dynamic Accelerator Slicer |
| Whole-GPU DRA roadmap | See sibling [`karta-kueue-dra`](../karta-kueue-dra) |

If you share your **GPU hardware model** (e.g. L40S, A100, H100) and whether the goal is **inference** or **training**, the ClusterPolicy / MIG profile can be pinned to exact operator YAML for that SKU.
