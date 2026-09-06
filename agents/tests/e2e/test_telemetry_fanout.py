from __future__ import annotations

from pathlib import Path

# These assertions read files by their repo-relative path. pytest runs with
# ``agents/`` as its rootdir (pyproject.toml), so resolving them against the
# process's working directory only worked when the suite happened to be started
# from the repository root — from anywhere else every one of them failed on
# FileNotFoundError. Anchor on this file instead.
REPO_ROOT = Path(__file__).resolve().parents[3]


def test_single_exporter_conformance():
    """Agent processes emit OTLP to exactly one endpoint (the tier collector).

    - agents/config/telemetry.py defines a single OTLP_HTTP_ENDPOINT pointing to
      http://agent-otel-collector.agentic-netops-agents.svc:4318
    - Observe.init is called exactly once in that module
    - Each process server calls init_telemetry() exactly once.
    """
    telemetry_py = (REPO_ROOT / "agents/config/telemetry.py").read_text(encoding="utf-8")
    assert "agent-otel-collector.agentic-netops-agents.svc:4318" in telemetry_py
    assert telemetry_py.count("Observe.init(") == 1
    # No upstream collector in agents — only the tier collector is referenced
    assert "otel-collector.agentic-netops-system" not in telemetry_py
    # Each server/supervisor performs a single init_telemetry call
    files = [
        "agents/supervisors/provisioning/main.py",
        "agents/provisioning/mapper/server.py",
        "agents/provisioning/allocator/server.py",
        "agents/provisioning/deployer/server.py",
    ]
    for f in files:
        content = (REPO_ROOT / f).read_text(encoding="utf-8")
        assert content.count("init_telemetry(") == 1, f"expected single init_telemetry in {f}"


def test_two_sink_fanout_configuration():
    """Collector fans out to two sinks from one incoming emission (Decision 8).

    Validate through the telemetry.yaml content that the traces pipeline exports
    to both clickhouse and otlp/feature001.
    """
    text = (REPO_ROOT / "deploy/agents/telemetry.yaml").read_text(encoding="utf-8")
    # The traces pipeline uses both exporters
    assert "pipelines:" in text and "traces:" in text
    assert "exporters: [clickhouse, otlp/feature001]" in text
    # And the OTLP receiver is configured
    assert "receivers: [otlp]" in text


def test_two_sink_trace_id_equality():
    """The same W3C trace_id is exported to both sinks without rewrite.

    Rationale:
    - A single OTLP receiver (`receivers: [otlp]`) feeds one traces pipeline.
    - The only processor is `batch`, which does not rewrite trace ids.
    - The traces pipeline exports to both `clickhouse` and `otlp/feature001`.
    - common.telemetry.get_trace_correlation_id derives correlation-id from the
      active span's trace id (format(ctx.trace_id, "032x")), so the correlation
      id equals the W3C trace_id that both exporters carry unchanged.

    This ensures one request is recoverable as one trace across both sinks
    without timestamp matching.
    """
    text = (REPO_ROOT / "deploy/agents/telemetry.yaml").read_text(encoding="utf-8")
    assert "receivers: [otlp]" in text
    assert "processors: [batch]" in text
    assert "exporters: [clickhouse, otlp/feature001]" in text
    # Sanity: no processors present that could rewrite ids or spans. The scan
    # skips comments — telemetry.yaml documents the span attributes the SDK
    # emits, and reading that prose as a configured `attributes:` processor
    # failed this assertion on a file that configures only `batch`.
    configured = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    for rewriting_processor in ("attributes:", "transform:", "tail_sampling", "spanmetrics"):
        assert rewriting_processor not in configured, (
            f"{rewriting_processor!r} is configured in the collector; a processor that can "
            "rewrite ids or spans breaks the one-trace-across-both-sinks property"
        )

    # The correlation-id binding is the W3C trace id (32 lowercase hex)
    telem = (REPO_ROOT / "agents/common/telemetry.py").read_text(encoding="utf-8")
    assert 'format(ctx.trace_id, "032x")' in telem

    # Documentation in telemetry.yaml captures the trace_id-as-correlation-id contract
    assert "The W3C trace_id on every span" in text
