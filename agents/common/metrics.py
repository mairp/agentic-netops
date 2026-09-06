"""Intent-tier metrics helpers (US5 — Phase 8).

This module defines a stable, opinionated metrics surface for the intent tier.
All instruments are named with the agentic_netops_agent_* prefix (T329) so the
feature-001 collector's filter keeps them without changes.

Provided counters/histograms:
- agentic_netops_agent_stage_requests_total{stage}
- agentic_netops_agent_stage_success_total{stage}
- agentic_netops_agent_stage_failures_total{stage}
- agentic_netops_agent_stage_latency_seconds{stage} (histogram)
- agentic_netops_agent_confirm_total
- agentic_netops_agent_decline_total
- agentic_netops_agent_refused_unsafe_total
- agentic_netops_agent_model_calls_total{model}
- agentic_netops_agent_model_tokens_total{model,kind="input|output"}
- agentic_netops_agent_model_cost_usd_total{model}

The helpers are side-effect free when no OpenTelemetry metrics provider is
initialized: they construct instruments on first use and no-op on failure.
"""
from __future__ import annotations

from dataclasses import dataclass

from opentelemetry import metrics
from opentelemetry.metrics import Counter, Histogram

_PREFIX = "agentic_netops_agent_"


def _enforce_name(name: str) -> str:
    if not name.startswith(_PREFIX):
        raise ValueError(f"metric names must start with '{_PREFIX}': {name}")
    return name


@dataclass
class _StageInstruments:
    req: Counter
    ok: Counter
    fail: Counter
    lat: Histogram


class Metrics:
    def __init__(self) -> None:
        self._meter = metrics.get_meter("agentic-netops.intent_tier")
        # Stage instruments (per stage label)
        self._stage_req = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_stage_requests_total"),
            description="Per-stage request count",
            unit="1",
        )
        self._stage_ok = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_stage_success_total"),
            description="Per-stage successful request count",
            unit="1",
        )
        self._stage_fail = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_stage_failures_total"),
            description="Per-stage failed request count",
            unit="1",
        )
        self._stage_lat = self._meter.create_histogram(
            name=_enforce_name("agentic_netops_agent_stage_latency_seconds"),
            description="Per-stage request latency (seconds)",
            unit="s",
        )
        # Confirmation / decline / refusal
        self._confirm = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_confirm_total"),
            description="Confirmation decisions recorded",
            unit="1",
        )
        self._decline = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_decline_total"),
            description="Decline decisions recorded",
            unit="1",
        )
        self._refused_unsafe = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_refused_unsafe_total"),
            description="Refusals due to unsupported/unsafe requests",
            unit="1",
        )
        # Model usage
        self._model_calls = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_model_calls_total"),
            description="Model call count",
            unit="1",
        )
        self._model_tokens = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_model_tokens_total"),
            description="Token usage",
            unit="1",
        )
        self._model_cost = self._meter.create_counter(
            name=_enforce_name("agentic_netops_agent_model_cost_usd_total"),
            description="Estimated model cost (USD)",
            unit="USD",
        )

    # --------- Stage metrics (T323–T325) ---------
    def inc_stage_request(self, stage: str) -> None:
        self._stage_req.add(1, attributes={"stage": stage})

    def record_stage_result(self, *, stage: str, success: bool, latency_seconds: float | None = None) -> None:
        if success:
            self._stage_ok.add(1, attributes={"stage": stage})
        else:
            self._stage_fail.add(1, attributes={"stage": stage})
        if latency_seconds is not None:
            try:
                self._stage_lat.record(float(latency_seconds), attributes={"stage": stage})
            except Exception:
                # Defensive: ignore bad values
                pass

    # --------- Confirmation / decline / refusal (T326–T327) ---------
    def inc_confirmation(self) -> None:
        self._confirm.add(1)

    def inc_decline(self) -> None:
        self._decline.add(1)

    def inc_refused_unsafe(self) -> None:
        self._refused_unsafe.add(1)

    # --------- Model usage (T328) ---------
    def model_call(self, *, model: str, tokens_in: int = 0, tokens_out: int = 0, cost_usd: float = 0.0) -> None:
        self._model_calls.add(1, attributes={"model": model})
        if tokens_in:
            self._model_tokens.add(int(tokens_in), attributes={"model": model, "kind": "input"})
        if tokens_out:
            self._model_tokens.add(int(tokens_out), attributes={"model": model, "kind": "output"})
        if cost_usd:
            # store cents to avoid floating drift? we keep USD for readability
            try:
                self._model_cost.add(float(cost_usd), attributes={"model": model})
            except Exception:
                pass


# Singleton (idempotent construction under the default provider)
_metrics: Metrics | None = None


def get_metrics() -> Metrics:
    global _metrics
    if _metrics is None:
        _metrics = Metrics()
    return _metrics
