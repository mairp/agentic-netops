"""Live SRv6 capability + site inventory reads (feature 004, T467/T469/T623).

The supervisor must refuse an SRv6 request on a lab profile where the
capability has never been proven (refusal R4, contracts/operator-phrasings.md
§3) BEFORE the mapper maps anything and before any identifier is claimed —
so the graph reads the capability here, from the live cluster, at the top of
the mapper node.

What is read: the ConfigMap ``fabric-compat-pins`` in namespace
``agentic-netops-system``:

* ``cap-sai-srv6`` — available is True iff the value is exactly ``"true"``
  AND the read succeeded. ANY failure (ConfigMap absent, RBAC 403, timeout,
  malformed body) yields the fail-closed result
  ``SRv6Capability(available=False, supported=(), verifiable_attachments=())``:
  an unreadable cluster must never enable the feature.
* ``srv6-supported`` — the supported variant set ("ip-vrf/vpn,steering"),
  the filter behind refusal R2 and the clarifications (T469).
* ``srv6-probe-attachments`` — the attachment points a probe client can
  verify ("leaf01/wan1,leaf02/wan1"); the verifiability set behind refusal
  R9 (T623, spec KL-009).
* ``lab-profile`` / ``sonic-image`` — carried for logs and diagnostics.

There is NO caching (T466): every call re-reads the ConfigMap. A profile
flip is a live fact, not a warm-up artifact, and a refusal must never be
served from a stale cache that said "true".

Identity (mirrors ``common/audit.py``): in-cluster the API server is
``https://kubernetes.default.svc:443`` with the pod's ServiceAccount bearer
token and CA bundle; the ``AGENTIC_NETOPS_API_ENDPOINT`` /
``AGENTIC_NETOPS_BEARER_TOKEN`` / ``AGENTIC_NETOPS_VERIFY_TLS`` /
``AGENTIC_NETOPS_CA_BUNDLE`` env overrides serve the tests and e2e. The
supervisor holds exactly one scoped permission on this object (get on this
one ConfigMap by resourceName — deploy/agents/namespace-rbac.yaml) and
nothing else.

The HTTP call itself is a module-level seam (:func:`_http_get`) so the unit
tests stub the transport without a cluster (T466/T623 monkeypatch it).
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass

import httpx

from common.audit import _IN_CLUSTER_API, _TOKEN_FILE, _ca_bundle

logger = logging.getLogger("agentic_netops.provisioning.capability")

CAPABILITY_NAMESPACE = "agentic-netops-system"
CAPABILITY_CONFIGMAP = "fabric-compat-pins"

_CAPABILITY_KEY = "cap-sai-srv6"
_SUPPORTED_KEY = "srv6-supported"
_ATTACHMENTS_KEY = "srv6-probe-attachments"
_PROFILE_KEY = "lab-profile"
_IMAGE_KEY = "sonic-image"

_REQUEST_TIMEOUT_SECONDS = 5.0


@dataclass(frozen=True)
class SRv6Capability:
    """What this lab profile can do with SRv6, read live (never cached)."""

    available: bool
    supported: tuple[str, ...]
    verifiable_attachments: tuple[str, ...]
    lab_profile: str | None = None
    sonic_image: str | None = None


@dataclass(frozen=True)
class SiteInventory:
    """The site's valid names (the Python mirror of pkg/migration/site.go).

    An unset env validates NOTHING, exactly like the Go side: the unit
    tests and a misconfigured deployment never invent a site.
    """

    nodes: tuple[str, ...] = ()
    attachments: tuple[str, ...] = ()
    spines: tuple[str, ...] = ()


# ---------------------------------------------------------------------------
# HTTP seam.
# ---------------------------------------------------------------------------
def _http_get(url: str, *, headers: dict[str, str], verify: bool | str, timeout: float) -> httpx.Response:
    """One GET. Module-level so tests stub the transport (T466/T623)."""
    return httpx.get(url, headers=headers, verify=verify, timeout=timeout)


def _identity() -> tuple[str, str, bool | str] | None:
    """(endpoint, bearer token, verify) — or None when identity-less.

    ``AGENTIC_NETOPS_BEARER_TOKEN`` overrides for the tests (with
    ``AGENTIC_NETOPS_API_ENDPOINT`` when set, else the in-cluster service
    name); otherwise the pod's mounted ServiceAccount token, replicating
    ``common/audit.py``'s resolution.
    """
    token = os.getenv("AGENTIC_NETOPS_BEARER_TOKEN")
    if token:
        endpoint = os.getenv("AGENTIC_NETOPS_API_ENDPOINT") or _IN_CLUSTER_API
        verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
        return endpoint, token, _ca_bundle() if verify else False
    if _TOKEN_FILE.exists():
        try:
            token = _TOKEN_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if token:
            verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
            return _IN_CLUSTER_API, token, _ca_bundle() if verify else False
    return None


def _split_csv(raw: str | None) -> tuple[str, ...]:
    """``"a, b"`` -> ``("a", "b")``; blank entries dropped, order kept."""
    if not raw:
        return ()
    return tuple(s.strip() for s in raw.split(",") if s.strip())


def read_capability() -> SRv6Capability:
    """Read the live capability. Fail-closed on EVERY error (T466)."""

    unavailable = SRv6Capability(available=False, supported=(), verifiable_attachments=())
    identity = _identity()
    if identity is None:
        # No cluster identity (out-of-cluster runs, unit tests): the
        # capability has not been proven here.
        return unavailable
    endpoint, token, verify = identity
    url = (
        f"{endpoint.rstrip('/')}/api/v1/namespaces/{CAPABILITY_NAMESPACE}"
        f"/configmaps/{CAPABILITY_CONFIGMAP}"
    )
    try:
        resp = _http_get(
            url,
            headers={"Authorization": f"Bearer {token}"},
            verify=verify,
            timeout=_REQUEST_TIMEOUT_SECONDS,
        )
    except Exception as exc:  # noqa: BLE001 - timeout, DNS, TLS: all mean unavailable
        logger.warning("capability read failed: %s", type(exc).__name__)
        return unavailable
    if resp.status_code // 100 != 2:
        logger.warning(
            "capability read rejected (HTTP %s) for %s/%s",
            resp.status_code,
            CAPABILITY_NAMESPACE,
            CAPABILITY_CONFIGMAP,
        )
        return unavailable
    try:
        body = resp.json()
        data = body["data"]
        if not isinstance(data, dict):
            raise ValueError("configmap data is not an object")
    except Exception:  # noqa: BLE001 - malformed body: unavailable
        logger.warning("capability read returned a malformed body")
        return unavailable

    available = data.get(_CAPABILITY_KEY) == "true"
    if not available:
        return unavailable
    return SRv6Capability(
        available=True,
        supported=_split_csv(data.get(_SUPPORTED_KEY)),
        verifiable_attachments=_split_csv(data.get(_ATTACHMENTS_KEY)),
        lab_profile=data.get(_PROFILE_KEY) or None,
        sonic_image=data.get(_IMAGE_KEY) or None,
    )


# ---------------------------------------------------------------------------
# Site inventory from env (the Go SiteInventoryFromEnv parity, T493's source).
# ---------------------------------------------------------------------------
def normalize_site_name(s: str) -> str:
    """Fold the spellings of one logical name together (site.go parity):
    case and separators are notation, not intent. Never invents a name."""
    return "".join(ch for ch in s.lower() if ch.isalnum() and ord(ch) < 128)


def _keys_of_json_map(raw: str | None) -> tuple[str, ...]:
    """The keys of a JSON string->string map with a non-empty value, sorted
    (``keysOfJSONMap`` parity). Unset or unparseable -> empty."""
    if not raw or not raw.strip():
        return ()
    try:
        parsed = json.loads(raw)
    except ValueError:
        return ()
    if not isinstance(parsed, dict):
        return ()
    return tuple(sorted(k for k, v in parsed.items() if v != ""))


def site_inventory() -> SiteInventory:
    """The site's valid node / attachment / spine names, from env.

    FABRIC_NODE_MAP / FABRIC_PORT_MAP are the SAME JSON maps the Go
    translator parses (pkg/migration/site.go); FABRIC_SPINE_NODES is the
    comma-separated spine list. Unset pieces validate nothing.
    """
    spines = _split_csv(os.getenv("FABRIC_SPINE_NODES"))
    return SiteInventory(
        nodes=_keys_of_json_map(os.getenv("FABRIC_NODE_MAP")),
        attachments=_keys_of_json_map(os.getenv("FABRIC_PORT_MAP")),
        spines=tuple(sorted(spines)),
    )


def knows(names: tuple[str, ...], want: str) -> bool:
    """True when ``want`` folds to one of ``names`` (site.go parity)."""
    norm = normalize_site_name(want)
    return any(normalize_site_name(n) == norm for n in names)
