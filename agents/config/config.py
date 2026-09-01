"""Tier configuration — ported from the subject's ``config/config.py`` with
the two cluster fixes (research.md Decision 2):

* ``DEFAULT_MESSAGE_TRANSPORT`` defaults to ``SLIM`` (the subject's default,
  carried forward; the supervisor's call helpers hard-require it).
* ``TRANSPORT_SERVER_ENDPOINT`` defaults to the in-cluster Service DNS name
  ``http://slim.ainetops-agents.svc:46357`` — the long variable name and the
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
    "TRANSPORT_SERVER_ENDPOINT", "http://slim.ainetops-agents.svc:46357"
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
MAPPER_ENDPOINT = os.getenv("MAPPER_ENDPOINT", "http://mapper.ainetops-agents.svc:9092")
ALLOCATOR_ENDPOINT = os.getenv("ALLOCATOR_ENDPOINT", "http://allocator.ainetops-agents.svc:9091")
DEPLOYER_ENDPOINT = os.getenv("DEPLOYER_ENDPOINT", "http://deployer.ainetops-agents.svc:9093")
# KUID allocation authority (Decision 11 — qualified: served groups + the
# aggregated API on svc/kuid-server:6443).
KUID_API_ENDPOINT = os.getenv("KUID_API_ENDPOINT", "https://kuid-server.kuid-system.svc:6443")
