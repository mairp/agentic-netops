"""Deployer worker executor — runs the deployment transaction agent.

Mirrors the allocator executor: extract the supervisor's fenced payload,
run :class:`~provisioning.deployer.agent.DeployerAgent`, and enqueue the
resulting A2A message (authoritative DataPart + SUBMISSION_JSON marker).
Every submission decision — envelope validation, translation, dry-run,
apply, rollback, convergence — happens inside the agent; this executor
only moves messages.
"""

from __future__ import annotations

import logging

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.types import (
    Task,
    UnsupportedOperationError,
)
from a2a.utils import new_task
from a2a.utils.errors import ServerError

logger = logging.getLogger("agentic_netops.network_deployer.agent_executor")

WORKER_NAME = "deployer"


class DeploymentAgentExecutor(AgentExecutor):
    """Call DeployerAgent and emit its authoritative message."""

    def __init__(self) -> None:
        from provisioning.deployer.agent import DeployerAgent

        self._agent = DeployerAgent()

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        logger.debug("Received deployment request: %s", context.message)

        task: Task | None = context.current_task
        if task is None:
            task = new_task(context.message)
            await event_queue.enqueue_event(task)

        # The supervisor fences every payload it sends (T095); the agent's
        # ingest unwraps the fence itself.
        request_text = (
            context.message.parts[0].root.text
            if context.message and context.message.parts
            else ""
        )

        try:
            message, _payload = await self._agent.ainvoke(request_text)
        except Exception as exc:  # noqa: BLE001
            logger.exception("deployment failed: %s", exc)
            raise

        await event_queue.enqueue_event(message)
        logger.debug("Deployment execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
