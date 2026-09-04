"""Tools for calling provisioning workers (mapper, allocator, deployer)
via A2A over SLIM.

Ported from the subject's ``graph/tools.py`` with the feature-002
corrections (research.md Decision 2): the supervisor's call helpers
**hard-require** the SLIM transport (``REVERSE.md`` / contracts/
a2a-transport.md — this is not a soft default), and each call now carries
the FR-025/FR-026 discipline the subject lacked:

* a per-call timeout (``WORKER_CALL_TIMEOUT_SECONDS``);
* a bounded retry with backoff (``WORKER_CALL_RETRIES``);
* "worker unreachable" (transport failure) is distinguished from "worker
  returned a failure" (a well-formed A2A error) — FR-025/FR-026 require
  the operator to be told which specific worker is unavailable, not a
  generic error.

The functions return the raw A2A response; ``graph/graph.py`` performs
the DataPart-first extraction, marker fallback, and schema validation
before anything is routed onward (T096–T102).
"""

from __future__ import annotations

import asyncio
import logging
import os
import uuid

from a2a.types import (
    Message,
    MessageSendParams,
    Part,
    Role,
    SendMessageRequest,
    TextPart,
)
from agntcy_app_sdk.semantic.a2a.protocol import A2AProtocol

from common.exceptions import AuthError
from config.config import DEFAULT_MESSAGE_TRANSPORT, TRANSPORT_SERVER_ENDPOINT
from provisioning.allocator.card import AGENT_CARD as ALLOCATOR_CARD
from provisioning.deployer.card import AGENT_CARD as DEPLOYER_CARD
from provisioning.mapper.card import AGENT_CARD as MAPPER_CARD
from supervisors.provisioning.graph.shared import get_factory

logger = logging.getLogger("agentic_netops.provisioning.supervisor.tools")

# FR-025: per-call timeout + bounded retry with backoff.
WORKER_CALL_TIMEOUT_SECONDS = float(os.getenv("WORKER_CALL_TIMEOUT_SECONDS", "60"))
# The deployer's call legitimately contains the bounded convergence watch
# (deployment contract step 7), so its per-call bound must exceed that watch
# — otherwise the supervisor cuts the call off exactly when the outcome is
# about to be reported, and the operator is told the worker is unreachable
# for a deployment that in fact converged. The mapper and allocator keep the
# tighter default: neither waits on the fabric.
DEPLOYER_CALL_TIMEOUT_SECONDS = float(os.getenv("DEPLOYER_CALL_TIMEOUT_SECONDS", "210"))
WORKER_CALL_RETRIES = int(os.getenv("WORKER_CALL_RETRIES", "2"))
_RETRY_BACKOFF_SECONDS = 1.0


# ---------------------------------------------------------------------------
# T139 — the capability-to-card registry. The supervisor never hardcodes a
# topic or a card inline at a call site: every worker is reached through its
# AgentCard (whose ``id`` is the routable ``org/namespace/local_name`` the
# topic is derived from, contracts/a2a-transport.md), keyed here by the
# worker's advertised skill id (the A2A "capability").
# ---------------------------------------------------------------------------
CAPABILITY_CARDS = {
    MAPPER_CARD.skills[0].id: MAPPER_CARD,
    ALLOCATOR_CARD.skills[0].id: ALLOCATOR_CARD,
    DEPLOYER_CARD.skills[0].id: DEPLOYER_CARD,
}


def card_for_capability(capability_id: str):
    """Return the AgentCard advertising ``capability_id`` (T139).

    Raises KeyError for an unknown capability — a typo must fail loudly,
    never silently route to the wrong worker.
    """
    return CAPABILITY_CARDS[capability_id]


class WorkerUnavailableError(ConnectionError):
    """FR-026 — the named worker could not be reached over the transport.

    Distinct from a worker *failure* (the worker answered and said no):
    the operator is told which specific worker is unavailable, and the
    conversation stays resumable (thread state is checkpointed).
    """

    def __init__(self, worker: str, cause: BaseException | None = None):
        self.worker = worker
        super().__init__(f"worker '{worker}' is unavailable: {cause}")


def _require_slim() -> None:
    """The subject's hard requirement, kept verbatim in force: the
    supervisor's worker calls run only over SLIM (contracts/a2a-transport
    — the gateway is TLS with client-certificate verification)."""
    if DEFAULT_MESSAGE_TRANSPORT != "SLIM":
        raise ValueError("Only SLIM transport is supported for provisioning agents.")


async def _send(worker: str, card, text: str, *, timeout_seconds: float | None = None):
    """Build the transport + client, send one text message, with the
    FR-025 timeout/retry discipline. Returns the raw A2A response."""
    _require_slim()
    call_timeout = WORKER_CALL_TIMEOUT_SECONDS if timeout_seconds is None else timeout_seconds
    last_error: BaseException | None = None
    for attempt in range(WORKER_CALL_RETRIES + 1):
        try:
            factory = get_factory()
            transport = factory.create_transport(
                DEFAULT_MESSAGE_TRANSPORT,
                endpoint=TRANSPORT_SERVER_ENDPOINT,
                # The SLIM client resolves worker topics against its own
                # transport-local org/namespace, so this MUST stay in the
                # same namespace the workers register under
                # ("default/default/<topic>" — see provisioning/*/server.py),
                # otherwise every publish fails route lookup ("no matching
                # found") and the call times out into a None reply.
                name="default/default/provision_graph",
            )
            client = await factory.create_client(
                "A2A",
                agent_topic=A2AProtocol.create_agent_topic(card),
                transport=transport,
            )
            request = SendMessageRequest(
                id=str(uuid.uuid4()),
                params=MessageSendParams(
                    message=Message(
                        messageId=str(uuid.uuid4()),
                        role=Role.user,
                        parts=[Part(TextPart(text=text))],
                    )
                ),
            )
            return await asyncio.wait_for(client.send_message(request), timeout=call_timeout)
        except (TimeoutError, ConnectionError, OSError) as exc:
            # Transport-level failure: the worker is unreachable (FR-025/FR-026).
            last_error = exc
            logger.warning(
                "worker %s unreachable (attempt %d/%d): %s",
                worker,
                attempt + 1,
                WORKER_CALL_RETRIES + 1,
                exc,
            )
            if attempt < WORKER_CALL_RETRIES:
                await asyncio.sleep(_RETRY_BACKOFF_SECONDS * (attempt + 1))
        except AuthError as exc:
            # FR-024: an unauthenticated registration is refused — this is
            # a configuration failure, not a transient one; no retry.
            raise WorkerUnavailableError(worker, cause=exc) from exc
        except Exception as exc:  # noqa: BLE001
            # A well-formed A2A/protocol failure is a worker *failure*, not
            # an unreachability: report it as such (FR-025), no retry.
            logger.error("worker %s returned a failure: %s", worker, exc)
            raise WorkerUnavailableError(worker, cause=exc) from exc
    raise WorkerUnavailableError(worker, cause=last_error) from last_error


async def call_mapper_agent(user_message: str):
    """Call the mapper worker with the (already nonce-fenced) user text.

    ``user_message`` arrives pre-fenced by ``prompts.system.wrap_user_text``
    (T094/FR-028): the worker's model sees the operator's text only as a
    labelled data block.
    """
    return await _send("mapper", card_for_capability("map_network_request"), user_message)


async def call_allocator_agent(interpretation_json: str):
    """Call the allocator worker with the (nonce-fenced) interpretation.

    ``interpretation_json`` is the validated :class:`Interpretation`
    serialized canonically, fenced by ``wrap_worker_text`` (T095) — it is
    worker-returned text (the mapper's output) and stays data.
    """
    return await _send("allocator", card_for_capability("allocate_network_service"), interpretation_json)


async def call_deployer_agent(payload_json: str):
    """Call the deployer worker with the normalized intent payload.

    Reached only after both submission preconditions hold
    (``workflow_status == APPROVED`` and ``confirmation_2.decided ==
    "confirm"``, T124/T125) — enforced in ``graph._deployer_node`` before
    any call is made.
    """
    return await _send(
        "deployer",
        card_for_capability("deploy_network_service"),
        payload_json,
        timeout_seconds=DEPLOYER_CALL_TIMEOUT_SECONDS,
    )
