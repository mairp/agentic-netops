"""MappingAgentExecutor — calls MappingAgent and emits authoritative payload.

US1 (Phase 5): replace the Phase 2 stub with the real executor that invokes
MappingAgent, validates the Interpretation, and returns an A2A Message with
- authoritative DataPart carrying the JSON payload, and
- a TextPart carrying a human summary plus the MAPPED_JSON compatibility marker.
"""

from __future__ import annotations

import logging

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.types import Message, Task, UnsupportedOperationError
from a2a.utils import new_task
from a2a.utils.errors import ServerError

from provisioning.mapper.agent import MappingAgent

logger = logging.getLogger("devnet.network_mapping.agent_executor")

WORKER_NAME = "mapper"


class MappingAgentExecutor(AgentExecutor):
    """Executes the mapping by delegating to MappingAgent."""

    def __init__(self) -> None:
        self._agent = MappingAgent()

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

        # The mapper expects the user content already fenced by the supervisor
        # (T094); forward it verbatim.
        user_text = getattr(context.message, "parts", [])[0].root.text if context.message and context.message.parts else ""

        try:
            message, _interp = await self._agent.ainvoke(user_text)
        except Exception as exc:  # noqa: BLE001
            # Surface a typed server error — the transport will report it
            # upstream; the supervisor will reject as out-of-contract if no
            # structured payload is present.
            logger.exception("mapping failed: %s", exc)
            raise

        await event_queue.enqueue_event(message)
        logger.debug("Mapping execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
