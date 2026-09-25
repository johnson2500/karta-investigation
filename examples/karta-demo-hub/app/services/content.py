"""Serve baked-in runthrough markdown and presentation HTML."""

from __future__ import annotations

from pathlib import Path

import markdown


class ContentService:
    """Resolves per-demo content under CONTENT_ROOT/<demo-id>/."""

    def __init__(self, content_root: Path) -> None:
        self._root = content_root

    def demo_dir(self, demo_id: str) -> Path:
        return self._root / demo_id

    def runthrough_html(self, demo_id: str, filename: str) -> str | None:
        path = self.demo_dir(demo_id) / filename
        if not path.is_file():
            return None
        text = path.read_text(encoding="utf-8")
        return markdown.markdown(
            text,
            extensions=["fenced_code", "tables", "toc"],
        )

    def runthrough_sections(self, demo_id: str, filename: str) -> list[dict[str, str]]:
        """Split runthrough markdown on ## headings for step-through nav."""
        path = self.demo_dir(demo_id) / filename
        if not path.is_file():
            return []
        text = path.read_text(encoding="utf-8")
        sections: list[dict[str, str]] = []
        current_title = "Overview"
        current_lines: list[str] = []

        def flush() -> None:
            body = "\n".join(current_lines).strip()
            if not body and current_title == "Overview" and not sections:
                return
            sections.append(
                {
                    "title": current_title,
                    "html": markdown.markdown(
                        body or "_No content._",
                        extensions=["fenced_code", "tables"],
                    ),
                }
            )

        for line in text.splitlines():
            if line.startswith("## ") and not line.startswith("### "):
                flush()
                current_title = line[3:].strip()
                current_lines = []
            else:
                # Drop a leading single # title into overview body as bold line
                if line.startswith("# ") and not sections and not current_lines:
                    current_lines.append(f"**{line[2:].strip()}**")
                    current_lines.append("")
                else:
                    current_lines.append(line)
        flush()
        return sections

    def presentation_path(self, demo_id: str, rel: str = "index.html") -> Path | None:
        # presentation lives under demo_id/presentation/
        path = self.demo_dir(demo_id) / "presentation" / rel
        if path.is_file():
            return path
        # allow nested assets
        candidate = self.demo_dir(demo_id) / "presentation" / rel
        if candidate.is_file():
            return candidate
        return None

    def presentation_root(self, demo_id: str) -> Path | None:
        root = self.demo_dir(demo_id) / "presentation"
        return root if root.is_dir() else None
