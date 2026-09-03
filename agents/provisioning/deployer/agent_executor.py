"""Phase 2 stub executor for the deployer worker (T084).

The real flow — the APPROVED + confirmation-2 invariant check (data-model.md
§1), the translator dry-run, the declarative ``network.kubenet.dev/networks``
+ ``ainetops.io/srv6services`` submission into ``ainetops-intent``, the
convergence watch, and rollback (Decision 10) — lands in Phase 3. The stub
submits nothing: it completes with an explicit skeleton answer.
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

logger = logging.getLogger("devnet.network_deployer.agent_executor")

WORKER_NAME = "deployer"


class DeploymentAgentExecutor(AgentExecutor):
    """Stub: acknowledges the task and completes it as a skeleton."""

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

        await event_queue.enqueue_event(
            Message(
                message_id=str(uuid4()),
                role=Role.agent,
                metadata={"name": "Network Deployer Agent", "skeleton": True, "worker": WORKER_NAME},
                parts=[
                    Part(
                        TextPart(
                            text=(
                                "skeleton (Phase 2): deployer stub — nothing has "
                                "been submitted to the cluster. Submission lands in "
                                "Phase 3 behind the APPROVED + confirmation-2 invariant."
                            )
                        )
                    )
                ],
            )
        )
        logger.debug("Deployment stub execution completed")

    async def cancel(
        self,
        request: RequestContext,
        event_queue: EventQueue,
    ) -> Task | None:
        raise ServerError(error=UnsupportedOperationError())
