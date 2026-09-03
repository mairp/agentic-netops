"""KUID API client helpers for the allocator (US1 — Phase 5).

Implements:
- T211: client construction against KUID_API_ENDPOINT with bearer token
- T212: Claim object creation in namespace `kuid-system`
- T213: Claim status wait and timeout handling
- T214: Claim stamping with `agentic-netops.io/correlation-id`
- T215: Collision and exhaustion error surfacing (typed)
- T216: claim release by correlation-id on decline
- T217: claim release by correlation-id on rollback

Notes
-----
The pinned KUID server (research.md Decision 11) serves aggregated API
endpoints under the `kuid-server` Service. At that pin the served groups
include the `*.be.kuid.dev` families; some subject documentation also names
`id.kuid.dev`. The client below supports both — callers specify the group
and resource plural explicitly.

Authentication mirrors the audit Kubernetes-Event emission seam: a bearer
service-account token is discovered in-cluster, or may be provided via the
`AGENTIC_NETOPS_BEARER_TOKEN` env for tests. TLS verification is configurable via
`AGENTIC_NETOPS_VERIFY_TLS` (default on).

This module does not invent identifiers: it creates KUID Claims, stamps them
with the correlation-id label, and (best-effort) waits for status. The
allocator reads allocated values from the API (entry objects or claim
status), not by generating them locally (FR-013).
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

import httpx

from config.config import (
    EXTCOMM_INDEX,
    FABRIC_ASN,
    KUID_API_ENDPOINT,
    L2VNI_INDEX,
    L3VNI_INDEX,
    VLAN_INDEX,
)

logger = logging.getLogger("agentic_netops.network_allocator.kuid")

KUID_NAMESPACE = "kuid-system"
from common.telemetry import CORRELATION_LABEL


class KUIDAPIError(RuntimeError):
    """Base exception for KUID API errors."""


class KUIDCollisionError(KUIDAPIError):
    """A claim collided with an existing conflicting value (T215)."""


class KUIDExhaustionError(KUIDAPIError):
    """The pool is exhausted (T215)."""


@dataclass
class KUIDIdentity:
    endpoint: str
    token: str | None
    verify_tls: bool


def _resolve_identity() -> KUIDIdentity:
    endpoint = os.getenv("KUID_API_ENDPOINT", KUID_API_ENDPOINT)
    token = os.getenv("AGENTIC_NETOPS_BEARER_TOKEN") or None
    if token is None:
        try:
            with open("/var/run/secrets/kubernetes.io/serviceaccount/token", "r", encoding="utf-8") as fh:
                token = fh.read().strip() or None
        except OSError:
            token = None
    verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
    return KUIDIdentity(endpoint=endpoint, token=token, verify_tls=verify)


def _claim_id(claim: dict[str, Any], what: str) -> int:
    """The allocated integer for a served claim.

    The `*.be.kuid.dev` groups report it in ``status.id``; the older inline
    encodings are kept as a fallback so a different pin still works.
    """
    status = claim.get("status") or {}
    value = status.get("id")
    if value is None:
        value = status.get("value") or status.get("allocated") or status.get("assigned")
    if isinstance(value, int):
        return value
    try:
        return int(str(value))
    except Exception as exc:  # noqa: BLE001
        raise KUIDAPIError(f"{what} claim has no numeric id: {value!r}") from exc


class KUIDClient:
    """Thin HTTP client for the KUID aggregated API (T211).

    The caller supplies the concrete group/plural when creating a claim so
    both `id.kuid.dev` and the `*.be.kuid.dev` families are supported.
    """

    def __init__(self, identity: KUIDIdentity | None = None):
        self.identity = identity or _resolve_identity()
        self._client = httpx.Client(verify=self.identity.verify_tls, timeout=10.0)

    # ---------------- core helpers ----------------
    def _headers(self) -> dict[str, str]:
        hdrs = {"Content-Type": "application/json"}
        if self.identity.token:
            hdrs["Authorization"] = f"Bearer {self.identity.token}"
        return hdrs

    def _url(self, group: str, plural: str) -> str:
        endpoint = self.identity.endpoint.rstrip("/")
        if group == "":  # core
            return f"{endpoint}/api/v1/namespaces/{KUID_NAMESPACE}/{plural}"
        return f"{endpoint}/apis/{group}/v1alpha1/namespaces/{KUID_NAMESPACE}/{plural}"

    def _classify_http_error(self, status_code: int, body_text: str) -> None:
        low = body_text.lower()
        if status_code == 409 and ("already exists" in low or "conflict" in low):
            raise KUIDCollisionError(body_text)
        if status_code in (409, 422, 429) and ("exhaust" in low or "no available" in low):
            raise KUIDExhaustionError(body_text)
        raise KUIDAPIError(f"kuid api error {status_code}: {body_text[:300]}")

    # ---------------- T212: create a Claim ----------------
    def create_claim(
        self,
        *,
        group: str,
        plural: str,
        kind: str,
        spec: dict[str, Any],
        correlation_id: str,
        name: str | None = None,
        labels: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Create a claim object in namespace `kuid-system` (T212/T214).

        Stamps the claim with `agentic-netops.io/correlation-id`.
        """
        meta_labels = dict(labels or {})
        meta_labels[CORRELATION_LABEL] = correlation_id
        body = {
            "apiVersion": f"{group}/v1alpha1" if group else "v1",
            "kind": kind,
            "metadata": {
                "name": name or f"claim-{uuid4().hex[:12]}",
                "namespace": KUID_NAMESPACE,
                "labels": meta_labels,
            },
            "spec": spec,
        }
        url = self._url(group, plural)
        resp = self._client.post(url, headers=self._headers(), content=json.dumps(body))
        if resp.status_code // 100 != 2:
            self._classify_http_error(resp.status_code, resp.text)
        return resp.json()

    # ---------------- T213: wait for Claim status ----------------
    def wait_for_claim(
        self,
        *,
        group: str,
        plural: str,
        name: str,
        timeout_seconds: float = 20.0,
        poll_interval: float = 0.5,
    ) -> dict[str, Any]:
        """Poll the claim for a terminal status up to the timeout (T213).

        Returns the final claim object. A timeout raises KUIDAPIError.
        """
        url = self._url(group, plural) + f"/{name}"
        deadline = time.time() + timeout_seconds
        last_obj: dict[str, Any] | None = None
        while time.time() < deadline:
            resp = self._client.get(url, headers=self._headers())
            if resp.status_code // 100 != 2:
                self._classify_http_error(resp.status_code, resp.text)
            obj = resp.json()
            last_obj = obj
            status = obj.get("status") or {}
            # The served *.be.kuid.dev groups report the allocated integer in
            # status.id and readiness through a Ready condition.
            if status.get("id") is not None:
                return obj
            for cond in status.get("conditions") or []:
                if cond.get("type") == "Ready" and str(cond.get("status")) == "True":
                    return obj
            phase = (status.get("phase") or status.get("state") or "").lower()
            if phase in ("allocated", "bound", "ready", "succeeded"):
                return obj
            # Some pins report the value inline when ready
            if any(k in status for k in ("value", "allocated", "assigned")):
                return obj
            time.sleep(poll_interval)
        raise KUIDAPIError(f"claim {name} did not become ready within {timeout_seconds}s")

    # ---------------- T216/T217: release by correlation-id ----------------
    def release_by_correlation(self, correlation_id: str) -> int:
        """Delete all claim objects carrying the given correlation-id label.

        Scans the served claim resources we know about. Returns the number
        of deletions attempted (best-effort; non-2xx responses are logged)."""
        served: list[tuple[str, str]] = [
            ("id.kuid.dev", "claims"),
            ("ipam.be.kuid.dev", "ipclaims"),
            ("genid.be.kuid.dev", "genidclaims"),
            ("as.be.kuid.dev", "asclaims"),
            ("vlan.be.kuid.dev", "vlanclaims"),
            ("extcomm.be.kuid.dev", "extcommclaims"),
        ]
        deleted = 0
        sel = f"{CORRELATION_LABEL}={correlation_id}"
        for group, plural in served:
            url = self._url(group, plural)
            try:
                resp = self._client.get(url, headers=self._headers(), params={"labelSelector": sel})
                if resp.status_code // 100 != 2:
                    logger.debug("list %s: %s", plural, resp.text.strip()[:120])
                    continue
                items = resp.json().get("items", [])
                for item in items:
                    name = item.get("metadata", {}).get("name")
                    if not name:
                        continue
                    durl = url + f"/{name}"
                    dresp = self._client.delete(durl, headers=self._headers())
                    if dresp.status_code // 100 == 2:
                        deleted += 1
                    else:
                        logger.debug("delete %s/%s failed: %s", plural, name, dresp.text.strip()[:120])
            except Exception as exc:  # noqa: BLE001
                logger.debug("release scan failed for %s.%s: %s", plural, group, exc)
        return deleted

    # ---------------- Convenience allocators used by the agent ----------------
    def allocate_l2vni(self, correlation_id: str) -> int:
        return self._allocate_genid(correlation_id, L2VNI_INDEX, "l2vni")

    def allocate_l3vni(self, correlation_id: str) -> int:
        return self._allocate_genid(correlation_id, L3VNI_INDEX, "l3vni")

    def _allocate_genid(self, correlation_id: str, index: str, what: str) -> int:
        claim = self.create_claim(
            group="genid.be.kuid.dev", plural="genidclaims", kind="GENIDClaim",
            spec={"index": index}, correlation_id=correlation_id,
        )
        claim = self.wait_for_claim(
            group="genid.be.kuid.dev", plural="genidclaims",
            name=claim["metadata"]["name"],
        )
        return _claim_id(claim, what)

    def allocate_vlan(self, correlation_id: str) -> int:
        claim = self.create_claim(
            group="vlan.be.kuid.dev", plural="vlanclaims", kind="VLANClaim",
            spec={"index": VLAN_INDEX}, correlation_id=correlation_id,
        )
        claim = self.wait_for_claim(
            group="vlan.be.kuid.dev", plural="vlanclaims",
            name=claim["metadata"]["name"],
        )
        return _claim_id(claim, "vlan")

    def allocate_rd_rt(self, correlation_id: str) -> tuple[str, list[str], list[str]]:
        """One extended-community claim yields the route-target number; the
        RD reuses the same ASN:number pair so both stay derived from the
        allocation authority rather than generated locally (FR-013)."""
        claim = self.create_claim(
            group="extcomm.be.kuid.dev", plural="extcommclaims", kind="EXTCOMMClaim",
            spec={"index": EXTCOMM_INDEX}, correlation_id=correlation_id,
        )
        claim = self.wait_for_claim(
            group="extcomm.be.kuid.dev", plural="extcommclaims",
            name=claim["metadata"]["name"],
        )
        rt = f"{FABRIC_ASN}:{_claim_id(claim, 'rt')}"
        return rt, [rt], [rt]

