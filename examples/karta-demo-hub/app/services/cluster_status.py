"""Read-only cluster status for operator and demo namespace badges."""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


class ClusterStatusClient:
    """Uses in-cluster config when available; degrades gracefully locally."""

    def __init__(self) -> None:
        self._apps = None
        self._core = None
        self._available = False
        try:
            from kubernetes import client, config

            try:
                config.load_incluster_config()
            except config.ConfigException:
                try:
                    config.load_kube_config()
                except config.ConfigException:
                    logger.info("No kube config; status badges will show unknown")
                    return
            self._apps = client.AppsV1Api()
            self._core = client.CoreV1Api()
            self._available = True
        except Exception as exc:  # noqa: BLE001 — optional dependency path
            logger.warning("Kubernetes client unavailable: %s", exc)

    @property
    def available(self) -> bool:
        return self._available

    def _deploy_ready(self, namespace: str, name: str) -> bool:
        if not self._apps:
            return False
        try:
            dep = self._apps.read_namespaced_deployment(name, namespace)
            available = dep.status.available_replicas or 0
            return available >= 1
        except Exception:  # noqa: BLE001
            return False

    def _find_deploy_any_ns(self, name: str) -> bool:
        if not self._apps:
            return False
        try:
            items = self._apps.list_deployment_for_all_namespaces(
                field_selector=f"metadata.name={name}"
            ).items
            for dep in items:
                if (dep.status.available_replicas or 0) >= 1:
                    return True
        except Exception:  # noqa: BLE001
            return False
        return False

    def operator_status(self, operator: dict[str, Any]) -> dict[str, Any]:
        label = operator.get("label", operator.get("id", "?"))
        optional = bool(operator.get("optional"))
        if not self._available:
            return {
                "id": operator.get("id"),
                "label": label,
                "ready": None,
                "detail": "cluster API unavailable",
                "optional": optional,
            }

        ready = False
        detail = ""
        ns = operator.get("namespace", "")
        dep = operator.get("deployment", "")

        if operator.get("matchAnyNamespace"):
            ready = self._find_deploy_any_ns(dep) or self._deploy_ready(ns, dep)
            detail = "running (any namespace)" if ready else f"not found ({dep})"
        else:
            ready = self._deploy_ready(ns, dep)
            detail = f"{ns}/{dep}" if ready else f"missing {ns}/{dep}"

        if not ready and operator.get("altNamespace") and operator.get("altDeployment"):
            alt_ns = operator["altNamespace"]
            alt_dep = operator["altDeployment"]
            if self._deploy_ready(alt_ns, alt_dep):
                ready = True
                detail = f"{alt_ns}/{alt_dep}"

        return {
            "id": operator.get("id"),
            "label": label,
            "ready": ready,
            "detail": detail,
            "optional": optional,
        }

    def namespace_exists(self, namespace: str) -> bool | None:
        if not self._available or not self._core:
            return None
        try:
            self._core.read_namespace(namespace)
            return True
        except Exception:  # noqa: BLE001
            return False

    def demo_status(self, demo: dict[str, Any]) -> dict[str, Any]:
        ns = demo.get("namespace", "")
        exists = self.namespace_exists(ns)
        pod_count = None
        if exists and self._core:
            try:
                pods = self._core.list_namespaced_pod(ns).items
                pod_count = len(pods)
            except Exception:  # noqa: BLE001
                pod_count = None
        return {
            "namespace": ns,
            "namespaceExists": exists,
            "podCount": pod_count,
        }
