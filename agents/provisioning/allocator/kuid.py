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
`AGENTIC_NETOPS_VERIFY_TLS` (default on) and is anchored on the ServiceAccount
CA bundle mounted beside that token — the default trust store (certifi) holds
no cluster CA, so verifying against it can only ever fail.

This module does not invent identifiers locally: it first creates KUID Claims,
stamps them with the correlation-id label, and waits for status. On the pinned
lab, KUID's aggregated GENID/EXTCOMM families are broken, so those paths can
fall back to Kubernetes Lease objects whose creation is still atomic and
cluster-authoritative.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Any
from uuid import uuid4

import httpx

from config.config import (
    EXTCOMM_INDEX,
    FABRIC_ASN,
    KUID_ALLOCATION_FALLBACK,
    KUID_API_ENDPOINT,
    KUID_EXTCOMM_MAX,
    KUID_EXTCOMM_MIN,
    KUID_L2VNI_MAX,
    KUID_L2VNI_MIN,
    KUID_L3VNI_MAX,
    KUID_L3VNI_MIN,
    KUID_VLAN_MAX,
    KUID_VLAN_MIN,
    L2VNI_INDEX,
    L3VNI_INDEX,
    VLAN_INDEX,
)

logger = logging.getLogger("agentic_netops.network_allocator.kuid")

KUID_NAMESPACE = "kuid-system"
from common.telemetry import CORRELATION_LABEL

LEASE_LABELS = {
    "app.kubernetes.io/managed-by": "agentic-netops",
    "agentic-netops.io/allocation-backend": "lease",
}
LEASE_CORRELATION_ANNOTATION = "agentic-netops.io/correlation-id"
LEASE_ID_ANNOTATION = "agentic-netops.io/allocated-id"


class KUIDAPIError(RuntimeError):
    """Base exception for KUID API errors."""


class KUIDCollisionError(KUIDAPIError):
    """A claim collided with an existing conflicting value (T215)."""


class KUIDExhaustionError(KUIDAPIError):
    """The pool is exhausted (T215)."""


# In-cluster ServiceAccount material. The token authenticates the claim; the
# ca.crt beside it is the ONLY trust anchor that validates the API server's
# certificate. Both appear together, and only when the pod actually mounts its
# service-account token (deploy/agents/allocator.yaml).
SA_TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CACERT_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


@dataclass
class KUIDIdentity:
    endpoint: str
    token: str | None
    verify_tls: bool
    ca_bundle: str | None = None

    @property
    def verify(self) -> bool | str:
        """The value httpx should verify with.

        A CA bundle path when we have one (the in-cluster anchor), else the
        plain on/off switch. `verify=True` means the default trust store,
        which contains no cluster CA — see :func:`_resolve_identity`.
        """
        if not self.verify_tls:
            return False
        return self.ca_bundle or True


def _resolve_identity() -> KUIDIdentity:
    endpoint = os.getenv("KUID_API_ENDPOINT", KUID_API_ENDPOINT)
    token = os.getenv("AGENTIC_NETOPS_BEARER_TOKEN") or None
    if token is None:
        try:
            with open(SA_TOKEN_FILE, "r", encoding="utf-8") as fh:
                token = fh.read().strip() or None
        except OSError:
            token = None
    verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
    ca_bundle = os.getenv("AGENTIC_NETOPS_CA_BUNDLE") or None
    if ca_bundle is None and os.path.exists(SA_CACERT_FILE):
        ca_bundle = SA_CACERT_FILE
    if verify and ca_bundle is None:
        # Verifying an in-cluster endpoint against certifi always ends in
        # CERTIFICATE_VERIFY_FAILED ("unable to get local issuer certificate"),
        # and the failure surfaces four hops away as an opaque A2A -32603. Say
        # so here, where the cause is still visible.
        logger.warning(
            "no cluster CA bundle at %s (is automountServiceAccountToken enabled?); "
            "TLS verification of %s will fail against the default trust store",
            SA_CACERT_FILE,
            endpoint,
        )
    return KUIDIdentity(endpoint=endpoint, token=token, verify_tls=verify, ca_bundle=ca_bundle)


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
    both `id.kuid.dev` and the `*.be.kuid.dev` families are supported. When
    the pinned server rejects a pool, Kubernetes Leases provide a narrow
    fallback allocation authority in the same namespace.
    """

    def __init__(self, identity: KUIDIdentity | None = None):
        self.identity = identity or _resolve_identity()
        self._client = httpx.Client(verify=self.identity.verify, timeout=10.0)

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

    def _lease_url(self) -> str:
        endpoint = self.identity.endpoint.rstrip("/")
        return f"{endpoint}/apis/coordination.k8s.io/v1/namespaces/{KUID_NAMESPACE}/leases"

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
        """Delete all claim/lease objects carrying the given correlation-id.

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
        if KUID_ALLOCATION_FALLBACK == "lease":
            deleted += self._release_fallback_leases(correlation_id)
        return deleted

    # ---------------- Kubernetes Lease fallback for broken served pools -----
    def _fallback_enabled(self) -> bool:
        return KUID_ALLOCATION_FALLBACK == "lease"

    @staticmethod
    def _label_value(value: str) -> str:
        v = re.sub(r"[^A-Za-z0-9_.-]+", "-", value)[:63].strip("-.")
        return v or "default"

    def _fallback_selector(self, kind: str, index: str) -> str:
        labels = dict(LEASE_LABELS)
        labels["agentic-netops.io/allocation-pool"] = self._label_value(index)
        return ",".join(f"{k}={v}" for k, v in labels.items())

    def _fallback_lease_name(self, kind: str, index: str, value: int) -> str:
        prefix = self._label_value(f"agentic-netops-{kind}-{index}").lower()
        return f"{prefix}-{value}"

    def _fallback_lease_body(self, kind: str, index: str, value: int, correlation_id: str) -> dict[str, Any]:
        labels = dict(LEASE_LABELS)
        labels["agentic-netops.io/allocation-kind"] = self._label_value(kind)
        labels["agentic-netops.io/allocation-pool"] = self._label_value(index)
        return {
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": {
                "name": self._fallback_lease_name(kind, index, value),
                "namespace": KUID_NAMESPACE,
                "labels": labels,
                "annotations": {
                    LEASE_CORRELATION_ANNOTATION: correlation_id,
                    LEASE_ID_ANNOTATION: str(value),
                },
            },
            "spec": {
                "holderIdentity": correlation_id[:63] or "agentic-netops",
                "leaseDurationSeconds": 315360000,
            },
        }

    def _allocate_fallback_lease(
        self,
        *,
        kind: str,
        index: str,
        first: int,
        last: int,
        correlation_id: str,
    ) -> int:
        url = self._lease_url()
        selector = self._fallback_selector(kind, index)
        for _ in range(4):
            resp = self._client.get(url, headers=self._headers(), params={"labelSelector": selector})
            if resp.status_code // 100 != 2:
                self._classify_http_error(resp.status_code, resp.text)
            used: set[int] = set()
            for item in resp.json().get("items", []):
                raw = (item.get("metadata") or {}).get("annotations", {}).get(LEASE_ID_ANNOTATION)
                try:
                    used.add(int(str(raw)))
                except Exception:  # noqa: BLE001
                    continue
            for value in range(first, last + 1):
                if value in used:
                    continue
                body = self._fallback_lease_body(kind, index, value, correlation_id)
                create = self._client.post(url, headers=self._headers(), content=json.dumps(body))
                if create.status_code // 100 == 2:
                    logger.warning(
                        "allocated %s %s from Kubernetes Lease fallback because KUID %s is unavailable",
                        kind,
                        value,
                        index,
                    )
                    return value
                if create.status_code == 409:
                    used.add(value)
                    continue
                self._classify_http_error(create.status_code, create.text)
        raise KUIDExhaustionError(f"no available {kind} ids in {index} ({first}-{last})")

    def _release_fallback_leases(self, correlation_id: str) -> int:
        url = self._lease_url()
        selector = ",".join(f"{k}={v}" for k, v in LEASE_LABELS.items())
        try:
            resp = self._client.get(url, headers=self._headers(), params={"labelSelector": selector})
            if resp.status_code // 100 != 2:
                logger.debug("list fallback leases: %s", resp.text.strip()[:120])
                return 0
            deleted = 0
            for item in resp.json().get("items", []):
                meta = item.get("metadata") or {}
                if meta.get("annotations", {}).get(LEASE_CORRELATION_ANNOTATION) != correlation_id:
                    continue
                name = meta.get("name")
                if not name:
                    continue
                dresp = self._client.delete(url + f"/{name}", headers=self._headers())
                if dresp.status_code // 100 == 2:
                    deleted += 1
                else:
                    logger.debug("delete fallback lease %s failed: %s", name, dresp.text.strip()[:120])
            return deleted
        except Exception as exc:  # noqa: BLE001
            logger.debug("fallback lease release scan failed: %s", exc)
            return 0

    def _with_lease_fallback(
        self,
        *,
        what: str,
        index: str,
        first: int,
        last: int,
        correlation_id: str,
        allocate,
    ) -> int:
        try:
            return allocate()
        except (KUIDCollisionError, KUIDExhaustionError):
            raise
        except KUIDAPIError as exc:
            if not self._fallback_enabled():
                raise
            logger.warning("KUID allocation for %s from %s failed (%s); using Lease fallback", what, index, exc)
            return self._allocate_fallback_lease(
                kind=what,
                index=index,
                first=first,
                last=last,
                correlation_id=correlation_id,
            )

    # ---------------- Convenience allocators used by the agent ----------------
    def allocate_l2vni(self, correlation_id: str) -> int:
        return self._with_lease_fallback(
            what="l2vni",
            index=L2VNI_INDEX,
            first=KUID_L2VNI_MIN,
            last=KUID_L2VNI_MAX,
            correlation_id=correlation_id,
            allocate=lambda: self._allocate_genid(correlation_id, L2VNI_INDEX, "l2vni"),
        )

    def allocate_l3vni(self, correlation_id: str) -> int:
        return self._with_lease_fallback(
            what="l3vni",
            index=L3VNI_INDEX,
            first=KUID_L3VNI_MIN,
            last=KUID_L3VNI_MAX,
            correlation_id=correlation_id,
            allocate=lambda: self._allocate_genid(correlation_id, L3VNI_INDEX, "l3vni"),
        )

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
        return self._with_lease_fallback(
            what="vlan",
            index=VLAN_INDEX,
            first=KUID_VLAN_MIN,
            last=KUID_VLAN_MAX,
            correlation_id=correlation_id,
            allocate=lambda: self._allocate_vlan(correlation_id),
        )

    def _allocate_vlan(self, correlation_id: str) -> int:
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
        """One allocation yields the route-target number; the RD reuses the
        same ASN:number pair so both stay derived from the cluster allocation
        authority rather than generated locally."""
        rt_id = self._with_lease_fallback(
            what="rt",
            index=EXTCOMM_INDEX,
            first=KUID_EXTCOMM_MIN,
            last=KUID_EXTCOMM_MAX,
            correlation_id=correlation_id,
            allocate=lambda: self._allocate_extcomm(correlation_id),
        )
        rt = f"{FABRIC_ASN}:{rt_id}"
        return rt, [rt], [rt]

    def _allocate_extcomm(self, correlation_id: str) -> int:
        claim = self.create_claim(
            group="extcomm.be.kuid.dev", plural="extcommclaims", kind="EXTCOMMClaim",
            spec={"index": EXTCOMM_INDEX}, correlation_id=correlation_id,
        )
        claim = self.wait_for_claim(
            group="extcomm.be.kuid.dev", plural="extcommclaims",
            name=claim["metadata"]["name"],
        )
        return _claim_id(claim, "rt")
