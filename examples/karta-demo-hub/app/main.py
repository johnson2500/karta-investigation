"""Karta demo gallery — guided UI for stepping through examples."""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.services import ClusterStatusClient, ContentService, DemoCatalogService

APP_DIR = Path(__file__).resolve().parent
CATALOG_PATH = Path(os.environ.get("CATALOG_PATH", APP_DIR.parent / "catalog.json"))
CONTENT_ROOT = Path(os.environ.get("CONTENT_ROOT", APP_DIR.parent / "content"))
ENABLED_DEMOS_PATH = Path(os.environ.get("ENABLED_DEMOS_PATH", "/app/config/enabled.json"))
PORT = int(os.environ.get("PORT", "8080"))

catalog = DemoCatalogService(CATALOG_PATH, ENABLED_DEMOS_PATH)
content = ContentService(CONTENT_ROOT)
cluster = ClusterStatusClient()

app = FastAPI(title="Karta demo gallery", docs_url=None, redoc_url=None)
templates = Jinja2Templates(directory=str(APP_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(APP_DIR / "static")), name="static")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def home(request: Request) -> HTMLResponse:
    operator_statuses = [cluster.operator_status(op) for op in catalog.operators]
    demos = []
    for demo in catalog.demos():
        demos.append(
            {
                **demo,
                "status": cluster.demo_status(demo),
                "operatorStatuses": [
                    cluster.operator_status(catalog.operator_by_id(oid) or {"id": oid, "label": oid})
                    for oid in demo.get("operators", [])
                ],
            }
        )
    return templates.TemplateResponse(
        request,
        "home.html",
        {
            "operators": operator_statuses,
            "demos": demos,
            "cluster_available": cluster.available,
        },
    )


@app.get("/demos/{demo_id}", response_class=HTMLResponse)
def demo_detail(request: Request, demo_id: str, step: int = 0) -> HTMLResponse:
    demo = catalog.demo_by_id(demo_id)
    if not demo:
        raise HTTPException(status_code=404, detail="Demo not found")

    sections = content.runthrough_sections(demo_id, demo["runthroughFile"])
    if step < 0:
        step = 0
    if sections and step >= len(sections):
        step = len(sections) - 1

    prev_demo, next_demo = catalog.neighbors(demo_id)
    op_statuses = [
        cluster.operator_status(catalog.operator_by_id(oid) or {"id": oid, "label": oid})
        for oid in demo.get("operators", [])
    ]

    return templates.TemplateResponse(
        request,
        "demo.html",
        {
            "demo": demo,
            "sections": sections,
            "step": step,
            "section": sections[step] if sections else None,
            "prev_demo": prev_demo,
            "next_demo": next_demo,
            "operator_statuses": op_statuses,
            "demo_status": cluster.demo_status(demo),
            "cluster_available": cluster.available,
            "has_presentation": content.presentation_root(demo_id) is not None,
        },
    )


@app.get("/demos/{demo_id}/presentation")
@app.get("/demos/{demo_id}/presentation/{asset_path:path}")
def demo_presentation(demo_id: str, asset_path: str = "index.html") -> FileResponse:
    demo = catalog.demo_by_id(demo_id)
    if not demo:
        raise HTTPException(status_code=404, detail="Demo not found")
    root = content.presentation_root(demo_id)
    if root is None:
        raise HTTPException(status_code=404, detail="Presentation not found")

    rel = asset_path.strip() or "index.html"
    if rel.endswith("/"):
        rel = rel.rstrip("/") or "index.html"
        if not rel.endswith(".html"):
            rel = f"{rel}/index.html" if rel != "index.html" else "index.html"

    # Prevent path traversal
    target = (root / rel).resolve()
    if not str(target).startswith(str(root.resolve())):
        raise HTTPException(status_code=400, detail="Invalid path")
    if target.is_dir():
        target = (target / "index.html").resolve()
        if not str(target).startswith(str(root.resolve())):
            raise HTTPException(status_code=400, detail="Invalid path")
    if not target.is_file():
        raise HTTPException(status_code=404, detail="Asset not found")
    return FileResponse(target)


@app.get("/api/status")
def api_status() -> dict:
    return {
        "clusterAvailable": cluster.available,
        "operators": [cluster.operator_status(op) for op in catalog.operators],
        "demos": [
            {"id": d["id"], "status": cluster.demo_status(d)} for d in catalog.demos()
        ],
    }


def main() -> None:
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=PORT, reload=False)


if __name__ == "__main__":
    main()
