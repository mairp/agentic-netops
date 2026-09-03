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

logger = logging.getLogger("agentic_netops.network_allocator.agent_executor")

WORKER_NAME = "allocator"


class AllocatorAgentExecutor(AgentExecutor):
    """US1: call AllocatorAgent and emit authoritative payload + marker (T230)."""

    def __init__(self) -> None:
        from provisioning.allocator.agent import AllocatorAgent
        self._agent = AllocatorAgent()

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

        # The supervisor fences worker-returned text with the validated Interpretation
        interp_text = getattr(context.message, "parts", [])[0].root.text if context.message and context.message.parts else ""

        try:
            message, _intent = await self._agent.ainvoke(interp_text)
        except Exception as exc:  # noqa: BLE001
            logger.exception("allocation failed: %s", exc)
            raise

        await event_queue.enqueue_event(message)
        logger.debug("Allocation execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
