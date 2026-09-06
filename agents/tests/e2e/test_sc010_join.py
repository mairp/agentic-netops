from __future__ import annotations

import json
from pathlib import Path

# pytest's rootdir is ``agents/``; a repo-relative Path() here only resolved
# when the suite was started from the repository root. Anchor on this file.
REPO_ROOT = Path(__file__).resolve().parents[3]
DASHBOARD = REPO_ROOT / "deploy" / "agents" / "dashboards" / "intent-tier.json"


def test_sc010_resource_lookup_query_filters_by_correlation_id():
    """Dashboard panel queries fabric resources by correlation id label (no timestamp join).

    Asserts the PromQL in deploy/agents/dashboards/intent-tier.json filters by
    label_agentic_netops_io_correlation_id, which is stamped from the trace-derived
    correlation id (agents/common/telemetry.py, deployer/allocator stampers).
    """
    path = DASHBOARD
    data = json.loads(path.read_text(encoding="utf-8"))
    panels = data.get("panels", [])
    # Find the fabric resources table
    table = next((p for p in panels if p.get("type") == "table" and "Fabric Resources" in p.get("title", "")), {})
    targets = table.get("targets", [])
    exprs = [t.get("expr", "") for t in targets]
    assert any("label_agentic_netops_io_correlation_id" in e for e in exprs), (
        "fabric panel must filter by correlation label"
    )


def test_no_timestamp_correlation_dashboard_link_uses_only_id():
    """In-dashboard link uses only correlation_id param (no time correlation fields)."""
    data = json.loads(DASHBOARD.read_text(encoding="utf-8"))
    panels = data.get("panels", [])
    table = next((p for p in panels if p.get("type") == "table" and "Fabric Resources" in p.get("title", "")), {})
    links = table.get("links", []) or table.get("fieldConfig", {}).get("defaults", {}).get("links", [])
    urls = [link.get("url", "") for link in links]
    assert any("correlation_id=" in u for u in urls), "table link must pass correlation_id"
    assert all("from=" not in u and "to=" not in u for u in urls), "link must not set time range params"
