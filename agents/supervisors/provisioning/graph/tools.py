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

logger = logging.getLogger("devnet.provisioning.supervisor.tools")

# FR-025: per-call timeout + bounded retry with backoff.
WORKER_CALL_TIMEOUT_SECONDS = float(os.getenv("WORKER_CALL_TIMEOUT_SECONDS", "60"))
WORKER_CALL_RETRIES = int(os.getenv("WORKER_CALL_RETRIES", "2"))
_RETRY_BACKOFF_SECONDS = 1.0


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


async def _send(worker: str, card, text: str):
    """Build the transport + client, send one text message, with the
    FR-025 timeout/retry discipline. Returns the raw A2A response."""
    _require_slim()
    last_error: BaseException | None = None
    for attempt in range(WORKER_CALL_RETRIES + 1):
        try:
            factory = get_factory()
            transport = factory.create_transport(
                DEFAULT_MESSAGE_TRANSPORT,
                endpoint=TRANSPORT_SERVER_ENDPOINT,
                name="devnet/provisioning/provision_graph",
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
            return await asyncio.wait_for(
                client.send_message(request), timeout=WORKER_CALL_TIMEOUT_SECONDS
            )
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
    return await _send("mapper", MAPPER_CARD, user_message)


async def call_allocator_agent(interpretation_json: str):
    """Call the allocator worker with the (nonce-fenced) interpretation.

    ``interpretation_json`` is the validated :class:`Interpretation`
    serialized canonically, fenced by ``wrap_worker_text`` (T095) — it is
    worker-returned text (the mapper's output) and stays data.
    """
    return await _send("allocator", ALLOCATOR_CARD, interpretation_json)


async def call_deployer_agent(payload_json: str):
    """Call the deployer worker with the normalized intent payload.

    Reached only after both submission preconditions hold
    (``workflow_status == APPROVED`` and ``confirmation_2.decided ==
    "confirm"``, T124/T125) — enforced in ``graph._deployer_node`` before
    any call is made.
    """
    return await _send("deployer", DEPLOYER_CARD, payload_json)
