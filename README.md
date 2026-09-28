# run-ai-karta

Investigation into Karta (Workload-Map).

## Secret scanning (gitleaks + detect-secrets)

This repo uses [pre-commit](https://pre-commit.com/) to block commits that introduce secrets. Hooks:

- **gitleaks** — scans staged changes for leaked credentials ([`.gitleaks.toml`](.gitleaks.toml) allowlists tooling artifacts such as `.secrets.baseline`)
- **detect-secrets** — compares against [`.secrets.baseline`](.secrets.baseline) so known false positives stay quiet

### One-time setup

```bash
# From the repo root
python3 -m pip install --user pre-commit   # or: brew install pre-commit
pre-commit install

# Confirm config is present (filename must be exactly .pre-commit-config.yaml — no trailing spaces)
ls -la .pre-commit-config.yaml .gitleaks.toml .secrets.baseline
```

### Everyday use

Hooks run automatically on `git commit`. To run them on demand:

```bash
pre-commit run --all-files
# Or only gitleaks:
pre-commit run gitleaks --all-files
```

### Refreshing the detect-secrets baseline

After adding intentional test fixtures that look like secrets (or clearing a false positive):

```bash
# Prefer the detect-secrets from the pre-commit env, or: pip install detect-secrets
detect-secrets scan > .secrets.baseline
git add .secrets.baseline
```

Then commit as usual. Do **not** put real credentials in the repo; if gitleaks fails on a real key, rotate it and remove it from history.

## Examples

Full index: [examples/README.md](examples/README.md).

**Multi-demo entrypoint:** [examples/karta-demo-hub](examples/karta-demo-hub) — install shared operators once, deploy a guided gallery UI, then step through each demo and apply its Helm chart on demand.

| Example | What it shows |
|---------|----------------|
| [karta-demo-hub](examples/karta-demo-hub) | Guided gallery UI + shared operator install for all demos. |
| [karta-grove-kueue](examples/karta-grove-kueue) | Karta + Grove + Kueue on one cluster. |
| [karta-rayjob-compound-crd](examples/karta-rayjob-compound-crd) | Zero-code RayJob map (no KAI/Grove required). |
| [karta-decoupled-scheduler](examples/karta-decoupled-scheduler) | Karta without KAI (default scheduler). |
| [karta-kueue-admission](examples/karta-kueue-admission) | RayJob + Kueue GPU quota queuing. |
| [karta-kueue-dra](examples/karta-kueue-dra) | Job + Kueue + DRA; Karta still needed. |
| [karta-openshift-workload-api](examples/karta-openshift-workload-api) | Bypass KAI: Karta + Grove + Workload API (+ fractional GPUs). |

## How the repo is structured

Each example under [`examples/`](examples/) is a **Helm chart of sample CRs**. Charts do **not** install operators by themselves — use that example’s `scripts/install-operators.sh` first. Every example also ships an HTML **`presentation/`** deck and a beginner **runthrough** (`*-runthrough.md` + `scripts/runthrough.sh`).

Typical layout:

| Path | Purpose |
|------|---------|
| `README.md` | Theme of the demo, what question it answers, install/verify steps; links to `presentation/` and runthrough near the top |
| `*-runthrough.md` | Beginner step-by-step lab (what each check proves) |
| `Chart.yaml` / `values.yaml` | Helm metadata and knobs (enable maps, sample workloads, quotas) |
| `templates/` | Rendered objects: Karta maps, Grove/Kueue/DRA/Workload samples, `NOTES.txt`, `_helpers.tpl` |
| `scripts/` | Operator install + verbose `runthrough.sh` (`INTERACTIVE=0`, `SKIP_OPERATORS=1`); some demos add teardown helpers |
| `presentation/` | HTML slideshow (`index.html` + `README.md`) — same chrome across examples; content is example-specific |
| Extra `*.md` | Optional deep-dives (field-by-field Karta walkthrough, fractional GPUs) |

```
run-ai-karta/
├── README.md                 ← this file
├── LICENSE
└── examples/
    ├── README.md             ← index of all demos (+ presentation + runthrough links)
    ├── karta-demo-hub/       ← guided gallery + shared operators (recommended multi-demo path)
    ├── karta-grove-kueue/
    ├── karta-rayjob-compound-crd/
    ├── karta-decoupled-scheduler/
    ├── karta-kueue-admission/
    ├── karta-kueue-dra/      ← also: karta-batch-job.md + uninstall-all.sh
    └── karta-openshift-workload-api/  ← fractional-gpus.md companion
```

**Gallery workflow** (step through all demos):

```bash
cd examples/karta-demo-hub
./scripts/install-shared-operators.sh
# build image from repo root — see examples/karta-demo-hub/README.md
helm upgrade --install karta-hub . -n karta-hub --create-namespace
# open the Route; apply each demo’s Helm chart from the UI when ready
```

**Standalone workflow** for any single example:

```bash
cd examples/<example-name>
# hands-on lab: open <example-name>-runthrough.md
# or: INTERACTIVE=0 SKIP_OPERATORS=0 ./scripts/runthrough.sh
./scripts/install-operators.sh
helm upgrade --install demo . -n demo --create-namespace
# follow that example’s README / runthrough for verify / teardown
# open presentation/index.html for the slide deck
```
