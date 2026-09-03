"""Telemetry bootstrap for the intent tier (US5 — Phase 8).

Implements:
- T314: one OTLP endpoint per agent process — each process calls
  ``init_telemetry(app_name=...)`` exactly once at startup.
- T315: points the OTLP endpoint to
  ``http://agent-otel-collector.agentic-netops-agents.svc:4318`` (OTLP/HTTP).

This module configures the ioa-observe SDK to export OpenTelemetry traces and
metrics to the tier-owned collector. The collector performs the single fan-out
(ClickHouse + forward to the feature-001 collector).

The ``app_name`` becomes the OTLP ``service.name`` resource attribute and is
used to identify the agent process (supervisor, mapper, allocator, deployer).
"""
from __future__ import annotations

import os
from typing import Any

from ioa_observe.sdk import Observe


# Single OTLP endpoint for every agent process (T314/T315): the tier-owned
# collector in namespace agentic-netops-agents, OTLP/HTTP on 4318.
OTLP_HTTP_ENDPOINT = os.getenv(
    "AGENT_OTLP_HTTP_ENDPOINT", "http://agent-otel-collector.agentic-netops-agents.svc:4318"
)


def init_telemetry(app_name: str, resource_attributes: dict[str, Any] | None = None) -> None:
    """Initialize the ioa-observe SDK for this process.

    Args:
        app_name: Stable process identity — becomes service.name.
        resource_attributes: Optional additional OpenTelemetry resource
            attributes to attach to every span/metric (e.g. tier labels).
    """
    attrs: dict[str, Any] = {
        "agentic-netops.owner": "agentic-netops",
        "agentic-netops.io/tier": "intent",
    }
    if resource_attributes:
        attrs.update(resource_attributes)

    # Observe.init wires both traces and metrics to the same endpoint by default.
    # We do not supply a custom exporter: the SDK will use the OTLP/HTTP exporter
    # pointed at ``OTLP_HTTP_ENDPOINT``.
    Observe.init(
        app_name=app_name,
        api_endpoint=OTLP_HTTP_ENDPOINT,
        enabled=True,
        resource_attributes=attrs,
        # We export traces/metrics only; SDK-managed API features are disabled.
        telemetry_enabled=False,
        observe_sync_enabled=False,
    )
