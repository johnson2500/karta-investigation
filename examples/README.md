# run-ai-karta examples

Helm showcases for Karta. Charts install **sample CRs only** — run each folder’s `scripts/install-operators.sh` first (or the shared hub script below).

## Demo gallery hub (recommended multi-demo path)

[karta-demo-hub](karta-demo-hub/) installs a guided UI and a single shared-operator script. Use it to step through demos one-by-one; apply each chart’s sample CRs from the UI’s copy-paste Helm commands when ready.

```bash
cd karta-demo-hub
./scripts/install-shared-operators.sh
# build image from repo root — see karta-demo-hub/README.md
helm upgrade --install karta-hub . -n karta-hub --create-namespace
```

Each example also includes (for standalone use):

- an HTML **`presentation/`** deck (open `presentation/index.html`; no build step)
- a beginner **`*-runthrough.md`** lab and a verbose **`scripts/runthrough.sh`** (`INTERACTIVE=0`, `SKIP_OPERATORS=1`)

**Cluster-scoped names:** Karta maps, ClusterQueues, ResourceFlavors, and DeviceClasses are cluster-scoped and owned by the Helm release that created them. Defaults are **chart-prefixed** (e.g. `dra-batch-job-v1`, `openshift-ai-batch-job-v1`) so demos can run side-by-side. Reusing the same name across charts causes `meta.helm.sh/release-name` ownership errors — uninstall the other release or override with unique `--set` values.

| Example | What it shows | Presentation | Runthrough |
|---------|----------------|--------------|------------|
| [karta-demo-hub](karta-demo-hub/) | Guided gallery UI + shared operators for all demos. | — | [README](karta-demo-hub/README.md) |
| [karta-grove-kueue](karta-grove-kueue/) | Karta + Grove + Kueue together: Grove cliques, Jobs queued by Kueue, Karta maps both. | [deck](karta-grove-kueue/presentation/) | [lab](karta-grove-kueue/karta-grove-kueue-runthrough.md) · [script](karta-grove-kueue/scripts/runthrough.sh) |
| [karta-rayjob-compound-crd](karta-rayjob-compound-crd/) | Karta maps a RayJob with YAML only — no custom Go, KAI, or Grove required. | [deck](karta-rayjob-compound-crd/presentation/) | [lab](karta-rayjob-compound-crd/karta-rayjob-compound-crd-runthrough.md) · [script](karta-rayjob-compound-crd/scripts/runthrough.sh) |
| [karta-decoupled-scheduler](karta-decoupled-scheduler/) | Karta works without KAI (PyTorchJob on default scheduler). | [deck](karta-decoupled-scheduler/presentation/) | [lab](karta-decoupled-scheduler/karta-decoupled-scheduler-runthrough.md) · [script](karta-decoupled-scheduler/scripts/runthrough.sh) |
| [karta-kueue-admission](karta-kueue-admission/) | RayJob + Kueue: one GPU quota admits first job, second waits (`nvidia.com/gpu`). | [deck](karta-kueue-admission/presentation/) | [lab](karta-kueue-admission/karta-kueue-admission-runthrough.md) · [script](karta-kueue-admission/scripts/runthrough.sh) |
| [karta-kueue-dra](karta-kueue-dra/) | Job + Kueue + DRA: same admit/queue story via DRA claims; Karta still maps the Job. | [deck](karta-kueue-dra/presentation/) | [lab](karta-kueue-dra/karta-kueue-dra-runthrough.md) · [script](karta-kueue-dra/scripts/runthrough.sh) |
| [karta-openshift-workload-api](karta-openshift-workload-api/) | OpenShift AI alternative to Run:ai/KAI: Karta + Grove + Kueue + Workload API; fractional GPU notes. | [deck](karta-openshift-workload-api/presentation/) | [lab](karta-openshift-workload-api/karta-openshift-workload-api-runthrough.md) · [script](karta-openshift-workload-api/scripts/runthrough.sh) |

## Typical layout

```
examples/karta-demo-hub/   # gallery UI + install-shared-operators.sh
examples/<name>/
  Chart.yaml
  values.yaml
  README.md                 # links presentation + runthrough near the top
  <name>-runthrough.md      # beginner step-by-step lab
  templates/                # Karta maps, sample CRs, NOTES.txt, _helpers.tpl
  scripts/
    install-operators.sh
    runthrough.sh           # verbose lab (INTERACTIVE / SKIP_OPERATORS)
    uninstall.sh            # demo teardown (KEEP_OPERATORS=1 by default)
  presentation/             # index.html + README.md (HTML slideshow)
  # optional extras: deep-dive *.md, uninstall-all.sh (dra)
```
