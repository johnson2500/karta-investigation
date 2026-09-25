# karta-demo-hub

Guided gallery UI for all `run-ai-karta` examples. Install shared operators once, deploy this chart, then step through demos in the browser — apply each demo’s sample CRs with the copy-paste Helm commands when you are ready.

This chart deploys **the UI only**. It does not install operators or demo sample CRs.

## Workflow

From the `run-ai-karta` repo root:

```bash
# 1. Shared operators (Karta, Kueue, Grove, KubeRay; Training Operator by default)
cd examples/karta-demo-hub
./scripts/install-shared-operators.sh
# Optional: INSTALL_TRAINING_OPERATOR=0 ./scripts/install-shared-operators.sh

# 2. Build the gallery image (context = repo root, not this folder)
# Default platform is linux/amd64 (OpenShift). Do not use arm64 for cluster deploys.
./scripts/build-image.sh
IMAGE=quay.io/<org>/karta-demo-hub:0.1.0 ./scripts/build-image.sh
podman push quay.io/<org>/karta-demo-hub:0.1.0

podman tag karta-demo-hub:0.1.0 quay.io/rh-ee-rjjohnso/karta-demo-hub:0.1.0
podman push quay.io/rh-ee-rjjohnso/karta-demo-hub:0.1.0

# 3. Install the hub
helm upgrade --install karta-hub ./examples/karta-demo-hub \
  -n karta-hub --create-namespace \
  --set image.repository=quay.io/rh-ee-rjjohnso/karta-demo-hub \
  --set image.tag=0.1.0

# 4. Open the Route
oc get route karta-hub -n karta-hub -o jsonpath='{.spec.host}{"\n"}'
```

In the UI: pick a demo → walk lab steps / presentation → copy the Helm install command → apply from the repo root → verify → uninstall when done → next demo.

Prefer `./scripts/install-shared-operators.sh` when using the gallery. Per-demo `scripts/install-operators.sh` files remain for standalone single-demo installs.

## What the UI shows

| Screen | Content |
|--------|---------|
| Home | Operator readiness badges (read-only) + ordered demo list |
| Demo detail | Lab step-through (from `*-runthrough.md`), embedded presentation, copy-ready install/verify/uninstall commands, namespace status |

No privileged apply: the ServiceAccount can only **get/list** namespaces, pods, and deployments.

## Chart knobs

See [`values.yaml`](values.yaml): image, Route host/TLS, `demos.enabled`, resources, RBAC toggle.

## Local app (optional)

```bash
cd examples/karta-demo-hub
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# Symlink or copy content for one demo, e.g.:
mkdir -p content/karta-grove-kueue
cp -R ../karta-grove-kueue/presentation content/karta-grove-kueue/
cp ../karta-grove-kueue/karta-grove-kueue-runthrough.md content/karta-grove-kueue/
export CATALOG_PATH=$PWD/catalog.json CONTENT_ROOT=$PWD/content
PYTHONPATH=$PWD python -m uvicorn app.main:app --reload --port 8080
```

## Related

- Full demo index: [`../README.md`](../README.md)
- Standalone charts under `examples/karta-*` (sample CRs only)
