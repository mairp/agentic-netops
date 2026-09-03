from __future__ import annotations

import types
import pytest


class DummyAResponse:
    def __init__(self, status_code: int = 200):
        self.status_code = status_code


class DummyAClient:
    """AsyncClient stub for readiness resume test."""

    def __init__(self, status_code: int = 200):
        self._status_code = status_code

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, *_args, **_kwargs):
        return DummyAResponse(self._status_code)


def test_worker_down_setup_and_health_degraded(monkeypatch):
    """T364/T365 — when a worker endpoint is unreachable, /v1/health is degraded and names it.

    This test sets all worker endpoints to a closed local port to force an unreachable probe.
    The independent witness is the JSON body of /v1/health (not the mutation call itself).
    """
    from fastapi.testclient import TestClient

    import supervisors.provisioning.main as main_mod

    # Worker-down setup (T364): endpoints point to an unreachable address
    main_mod.WORKER_ENDPOINTS = {
        "mapper": "http://127.0.0.1:1",
        "allocator": "http://127.0.0.1:1",
        "deployer": "http://127.0.0.1:1",
    }

    with TestClient(main_mod.app) as client:
        resp = client.get("/v1/health")
    assert resp.status_code == 503
    body = resp.json()
    assert body["status"] == "degraded"
    # T365: Health assertion names the down workers through an independent read path
    assert set(body["workers"]) == {"mapper", "allocator", "deployer"}
    assert all(v == "unreachable" for v in body["workers"].values())


def test_worker_down_resume_when_workers_recover(monkeypatch):
    """T366 — resuming health after a recovery yields status ok.

    We monkeypatch httpx.AsyncClient to a dummy that always returns 200 so /v1/health
    reports status ok with all workers ok.
    """
    from fastapi.testclient import TestClient

    import supervisors.provisioning.main as main_mod

    # Patch AsyncClient class used by the endpoint to return 200 for all GETs
    import httpx

    monkeypatch.setattr(httpx, "AsyncClient", lambda timeout=5: DummyAClient(status_code=200))  # type: ignore[attr-defined]

    # Configure any endpoints (they won't be used thanks to the dummy AsyncClient)
    main_mod.WORKER_ENDPOINTS = {
        "mapper": "http://does.not.matter:1234",
        "allocator": "http://does.not.matter:1234",
        "deployer": "http://does.not.matter:1234",
    }

    with TestClient(main_mod.app) as client:
        resp = client.get("/v1/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert set(body["workers"]) == {"mapper", "allocator", "deployer"}
    assert all(v == "ok" for v in body["workers"].values())
