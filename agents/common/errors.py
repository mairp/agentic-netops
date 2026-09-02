"""Degradation and unavailability messages for operator-facing surfaces.

Phase 9 (T377–T379): Provide clear, actionable user-facing messages for
three cross-cutting degradation cases that can occur independently of the
provisioning pipeline's logic:

- provider-unavailable (model provider outage or credentials invalid);
- transport-unavailable (A2A/SLIM gateway down or unreachable);
- cluster-API-unavailable (allocator/deployer writers cannot reach the API).

These helpers are side-effect free and purely format operator-facing text.
They do not import HTTP clients or touch the transport.
"""

from __future__ import annotations

from typing import Optional


def provider_unavailable_message(provider_label: str, detail: Optional[str] = None) -> str:
    """T377 — provider-unavailable degradation message.

    Args:
        provider_label: A short, operator-readable provider name (e.g. "OpenAI").
        detail: Optional diagnostic detail (e.g. status code or exception).

    Returns:
        A human-readable explanation with a suggestion to retry later or switch
        to a different configured provider.
    """
    base = (
        f"The model provider '{provider_label}' is currently unavailable, so this "
        "request cannot be processed right now. Nothing was submitted. "
        "Please try again later or switch to a different configured provider."
    )
    if detail:
        return f"{base} (detail: {detail})"
    return base


def transport_unavailable_message(transport_label: str = "SLIM", detail: Optional[str] = None) -> str:
    """T378 — transport-unavailable degradation message.

    Args:
        transport_label: The message-transport name (default: "SLIM").
        detail: Optional diagnostic detail.
    """
    base = (
        f"The agent message transport '{transport_label}' is unavailable, so worker "
        "calls could not be made. Your thread is kept; please retry after the "
        "transport recovers."
    )
    if detail:
        return f"{base} (detail: {detail})"
    return base


def cluster_api_unavailable_message(detail: Optional[str] = None) -> str:
    """T379 — cluster-API-unavailable degradation message.

    Returns an operator-facing explanation that the Kubernetes API could not be
    reached by the writer identity (allocator/deployer), and that no objects were
    submitted.
    """
    base = (
        "The Kubernetes API is currently unavailable or refusing the tier's writer "
        "identity, so no resources were submitted. Please check cluster health and "
        "retry; your thread is kept."
    )
    if detail:
        return f"{base} (detail: {detail})"
    return base


__all__ = [
    "provider_unavailable_message",
    "transport_unavailable_message",
    "cluster_api_unavailable_message",
]
