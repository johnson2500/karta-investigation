"""Demo catalog loader."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class DemoCatalogService:
    """Loads and filters the gallery catalog JSON."""

    def __init__(self, catalog_path: Path, enabled_path: Path | None = None) -> None:
        self._catalog_path = catalog_path
        self._enabled_path = enabled_path
        self._data: dict[str, Any] = {}
        self.reload()

    def reload(self) -> None:
        with self._catalog_path.open(encoding="utf-8") as fh:
            self._data = json.load(fh)

    @property
    def operators(self) -> list[dict[str, Any]]:
        return list(self._data.get("operators", []))

    def operator_by_id(self, operator_id: str) -> dict[str, Any] | None:
        for op in self.operators:
            if op.get("id") == operator_id:
                return op
        return None

    def _enabled_ids(self) -> set[str] | None:
        if self._enabled_path is None or not self._enabled_path.is_file():
            return None
        raw = self._enabled_path.read_text(encoding="utf-8").strip()
        if not raw:
            return None
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return set(parsed)
        return None

    def demos(self) -> list[dict[str, Any]]:
        enabled = self._enabled_ids()
        demos = list(self._data.get("demos", []))
        if enabled is not None:
            demos = [d for d in demos if d.get("id") in enabled]
        return sorted(demos, key=lambda d: d.get("order", 999))

    def demo_by_id(self, demo_id: str) -> dict[str, Any] | None:
        for demo in self.demos():
            if demo.get("id") == demo_id:
                return demo
        return None

    def neighbors(self, demo_id: str) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        demos = self.demos()
        for i, demo in enumerate(demos):
            if demo.get("id") == demo_id:
                prev_demo = demos[i - 1] if i > 0 else None
                next_demo = demos[i + 1] if i + 1 < len(demos) else None
                return prev_demo, next_demo
        return None, None
