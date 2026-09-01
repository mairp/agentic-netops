"""Phase 2 stub executor for the allocator worker (T083).

The real flow — KUID claim creation against the qualified served groups,
Ready-condition gating, entry-object readback of the allocated value
(research.md Decision 11), and the ``NormalizedServiceIntent`` output with
the ``DEPLOYMENT_JSON`` marker + authoritative ``DataPart`` — lands in
Phase 3. The stub keeps the worker's A2A app complete and importable; it
never allocates anything locally (FR-013).
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

logger = logging.getLogger("devnet.network_allocator.agent_executor")

WORKER_NAME = "allocator"


class AllocationAgentExecutor(AgentExecutor):
    """Stub: acknowledges the task and completes it as a skeleton."""

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        logger.debug("Received allocation request: %s", context.message)

        task: Task | None = context.current_task
        if task is None:
            task = new_task(context.message)
            await event_queue.enqueue_event(task)

        await event_queue.enqueue_event(
            Message(
                message_id=str(uuid4()),
                role=Role.agent,
                metadata={"name": "Network Allocator Agent", "skeleton": True, "worker": WORKER_NAME},
                parts=[
                    Part(
                        TextPart(
                            text=(
                                "skeleton (Phase 2): allocator stub — KUID claim "
                                "allocation lands in Phase 3. Nothing has been "
                                "allocated; no identifier has been generated locally (FR-013)."
                            )
                        )
                    )
                ],
            )
        )
        logger.debug("Allocation stub execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
