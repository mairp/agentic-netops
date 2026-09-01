"""Phase 2 stub executor for the mapper worker (T082).

The real structured-extraction flow (``MappingAgent`` over the LLM, the
``Interpretation`` schema, the ``MAPPED_JSON`` marker + authoritative
``DataPart`` — contracts/a2a-transport.md, FR-017) lands in Phase 3. The
stub exists so the worker's ``A2AStarletteApplication`` is complete and its
imports resolve now: a task is submitted, and it completes with an explicit
skeleton answer naming the worker — never a silent success that looks like a
mapped interpretation.
"""

from __future__ import annotations

import logging
from uuid import uuid4

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.types import (
    Message,
    Part,
    Role,
    Task,
    TextPart,
    UnsupportedOperationError,
)
from a2a.utils import new_task
from a2a.utils.errors import ServerError

logger = logging.getLogger("devnet.network_mapping.agent_executor")

WORKER_NAME = "mapper"


class MappingAgentExecutor(AgentExecutor):
    """Stub: acknowledges the task and completes it as a skeleton."""

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        logger.debug("Received mapping request: %s", context.message)

        task: Task | None = context.current_task
        if task is None:
            task = new_task(context.message)
            await event_queue.enqueue_event(task)

        await event_queue.enqueue_event(
            Message(
                message_id=str(uuid4()),
                role=Role.agent,
                metadata={"name": "Network Mapping Agent", "skeleton": True, "worker": WORKER_NAME},
                parts=[
                    Part(
                        TextPart(
                            text=(
                                "skeleton (Phase 2): mapper stub — the structured "
                                "extraction into an Interpretation lands in Phase 3. "
                                "Nothing has been interpreted; do not treat this as a mapping."
                            )
                        )
                    )
                ],
            )
        )
        logger.debug("Mapping stub execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
