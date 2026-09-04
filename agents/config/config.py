"""Tier configuration — ported from the subject's ``config/config.py`` with
the two cluster fixes (research.md Decision 2):

* ``DEFAULT_MESSAGE_TRANSPORT`` defaults to ``SLIM`` (the subject's default,
  carried forward; the supervisor's call helpers hard-require it).
* ``TRANSPORT_SERVER_ENDPOINT`` defaults to the in-cluster Service DNS name
  ``http://slim.agentic-netops-agents.svc:46357`` — the long variable name and the
  46357 data-plane port are the verified ones (the subject's
  ``http://localhost:46357`` is its Compose default; in the cluster the
  gateway is reached by Service DNS, and the README's ``:7080`` is wrong —
  REVERSE.md Finding 1).

Dropped deliberately (Decision 14 — "correct or drop"): the subject's
``CNC_*`` connection settings. The proprietary vendor-controller southbound
they fed is exactly what feature 001 replaced; no tier code talks to a CNC.
Nothing else changes: the env names are the ones the code reads.
"""

from __future__ import annotations

import os

from dotenv import load_dotenv

load_dotenv()  # Automatically loads from `.env` or `.env.local`

DEFAULT_MESSAGE_TRANSPORT = os.getenv("DEFAULT_MESSAGE_TRANSPORT", "SLIM")
TRANSPORT_SERVER_ENDPOINT = os.getenv(
    "TRANSPORT_SERVER_ENDPOINT", "http://slim.agentic-netops-agents.svc:46357"
)
FARM_AGENT_HOST = os.getenv("FARM_AGENT_HOST", "localhost")
FARM_AGENT_PORT = int(os.getenv("FARM_AGENT_PORT", "9999"))

# NFR-003 / SC-015 seam: provider selection is the LLM_MODEL prefix alone
# (common/llm.py). The value comes from the generated Secret llm-provider.
LLM_MODEL = os.getenv("LLM_MODEL", "")
## Oauth2 OpenAI Provider
OAUTH2_CLIENT_ID = os.getenv("OAUTH2_CLIENT_ID", "")
OAUTH2_CLIENT_SECRET = os.getenv("OAUTH2_CLIENT_SECRET", "")
OAUTH2_TOKEN_URL = os.getenv("OAUTH2_TOKEN_URL", "")
OAUTH2_BASE_URL = os.getenv("OAUTH2_BASE_URL", "")
OAUTH2_APPKEY = os.getenv("OAUTH2_APPKEY", "")

LOGGING_LEVEL = os.getenv("LOGGING_LEVEL", "INFO").upper()

ENABLE_HTTP = os.getenv("ENABLE_HTTP", "true").lower() in ("true", "1", "yes")

# ---------------------------------------------------------------------------
# Tier additions (feature 002) — worker Service DNS names the supervisor's
# /v1/health readiness probe and the NDJSON progress checks address. Overridable
# for out-of-cluster runs; the defaults are the in-cluster names.
# ---------------------------------------------------------------------------
MAPPER_ENDPOINT = os.getenv("MAPPER_ENDPOINT", "http://mapper.agentic-netops-agents.svc:9092")
ALLOCATOR_ENDPOINT = os.getenv("ALLOCATOR_ENDPOINT", "http://allocator.agentic-netops-agents.svc:9091")
DEPLOYER_ENDPOINT = os.getenv("DEPLOYER_ENDPOINT", "http://deployer.agentic-netops-agents.svc:9093")
# KUID allocation authority (Decision 11 — qualified: the served groups are
# reached through the Kubernetes aggregation layer, not by dialing
# svc/kuid-server directly. kuid-server presents a fixed placeholder serving
# certificate (CN=basic.default.svc, SANs localhost/basic.default.svc/127.0.0.1)
# that verifies for no name it is actually reached by — which is why its own
# APIServices are registered with insecureSkipTLSVerify. The aggregated path
# is served by the cluster API server, whose certificate DOES verify against
# the ServiceAccount CA bundle, so the allocator keeps TLS verification on.
KUID_API_ENDPOINT = os.getenv("KUID_API_ENDPOINT", "https://kubernetes.default.svc:443")
# The index each claim draws from. These are the KUID index objects the
# fabric deploys (deploy/kuid/indices.yaml). The allocator never invents an
# identifier locally; if a pinned KUID pool is broken it claims the same range
# from the Lease fallback named below.
L2VNI_INDEX = os.getenv("KUID_L2VNI_INDEX", "evpn-vni")
L3VNI_INDEX = os.getenv("KUID_L3VNI_INDEX", "evpn-vni")
VLAN_INDEX = os.getenv("KUID_VLAN_INDEX", "fabric-vlan")
EXTCOMM_INDEX = os.getenv("KUID_EXTCOMM_INDEX", "rt-index")
# The ASN half of a route-target / route-distinguisher; the claimed
# extended-community id supplies the number half.
FABRIC_ASN = os.getenv("FABRIC_ASN", "65000")
# The pinned aggregated kuid-server accepts VLANIndex but rejects GENIDIndex and
# EXTCOMMIndex on Kubernetes 1.31 (uint64/spec-conversion defects). Until an
# upstream image fixes those served groups, the allocator can fall back to
# atomic Kubernetes Lease objects in kuid-system for the broken pools.
KUID_ALLOCATION_FALLBACK = os.getenv("KUID_ALLOCATION_FALLBACK", "lease").lower()
KUID_L2VNI_MIN = int(os.getenv("KUID_L2VNI_MIN", "10000"))
KUID_L2VNI_MAX = int(os.getenv("KUID_L2VNI_MAX", "20000"))
KUID_L3VNI_MIN = int(os.getenv("KUID_L3VNI_MIN", "10000"))
# 14094, not 20000: SONiC needs a VLAN for every VNI, and the fabric renderer
# derives an L3VNI's VLAN as 4000 + (vni - 10000) into the reserved 4001-4094
# band (pkg/fabricplan/plan.go). An L3VNI above 14094 has no VLAN to derive, so
# a pool that can hand one out is a pool that silently starts failing every
# L3VPN and IRB at convergence once it gets there.
KUID_L3VNI_MAX = int(os.getenv("KUID_L3VNI_MAX", "14094"))
KUID_EXTCOMM_MIN = int(os.getenv("KUID_EXTCOMM_MIN", "1"))
KUID_EXTCOMM_MAX = int(os.getenv("KUID_EXTCOMM_MAX", "65535"))
KUID_VLAN_MIN = int(os.getenv("KUID_VLAN_MIN", "100"))
KUID_VLAN_MAX = int(os.getenv("KUID_VLAN_MAX", "4000"))
