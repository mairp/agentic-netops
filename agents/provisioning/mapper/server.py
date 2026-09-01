"""Mapper worker server — Phase 2 skeleton (T082).

Ports the subject's ``agents/provisioning/mapper/server.py`` structure
(``A2AStarletteApplication`` + ``DefaultRequestHandler`` + ``InMemoryTaskStore``
+ the ``/v1/health`` route, uvicorn on the subject's port 9092).

Phase 2 boundary: the ``AgentCard`` and ``AgentExecutor`` are stubs (routable
card id ``devnet/provisioning/network-mapping``, skill
``map_network_request``); ``/v1/health`` is a plain liveness — the A2A
session probe over SLIM and the transport registration
(``run_transport`` in the subject) are Phase 3 wiring, marked below.
"""

from __future__ import annotations

import asyncio
import logging

from a2a.server.apps import A2AStarletteApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Route
from uvicorn import Config, Server

from config.config import DEFAULT_MESSAGE_TRANSPORT, ENABLE_HTTP, TRANSPORT_SERVER_ENDPOINT
from provisioning.mapper.agent_executor import MappingAgentExecutor
from provisioning.mapper.card import AGENT_CARD

logger = logging.getLogger("devnet.network_mapping.server")
logging.basicConfig(level=logging.INFO)

WORKER = "mapper"
PORT = 9092  # subject's port, kept (contracts/supervisor-http.md)


# ---------------- HEALTH ----------------

async def liveness_probe(request) -> JSONResponse:
    """Phase 2: plain liveness. Phase 3 replaces the body with the subject's
    A2A-session probe (create transport + client over SLIM, 15 s timeout)
    once the transport registration is wired."""
    return JSONResponse(
        {
            "status": "alive",
            "worker": WORKER,
            "transport": DEFAULT_MESSAGE_TRANSPORT,
            "endpoint": TRANSPORT_SERVER_ENDPOINT,
        }
    )


# ---------------- HTTP APP ----------------


def build_http_server(a2a_app: A2AStarletteApplication) -> FastAPI:
    app_ = a2a_app.build()
    app_.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app_.router.routes.append(Route("/v1/health", liveness_probe, methods=["GET"]))
    return app_


def create_app() -> FastAPI:
    request_handler = DefaultRequestHandler(
        agent_executor=MappingAgentExecutor(),
        task_store=InMemoryTaskStore(),
    )

    server = A2AStarletteApplication(
        agent_card=AGENT_CARD,
        http_handler=request_handler,
    )

    return build_http_server(server)


app = create_app()


# ---------------- RUNNERS ----------------


async def run_http_server(server: A2AStarletteApplication) -> None:
    app_ = build_http_server(server)
    config = Config(app=app_, host="0.0.0.0", port=PORT, loop="asyncio")
    await Server(config).serve()


async def run_transport(server: A2AStarletteApplication) -> None:
    """Phase 3 hook: register this worker with the SLIM gateway over
    ``TRANSPORT_SERVER_ENDPOINT`` (AgntcyFactory transport + AppContainer
    session, as in the subject's ``run_transport``). Left as a marked hook
    so Phase 2 imports resolve without the cluster."""
    logger.info("transport registration for %s is Phase 3 wiring", WORKER)


# ---------------- MAIN ----------------


async def main(enable_http: bool) -> None:
    request_handler = DefaultRequestHandler(
        agent_executor=MappingAgentExecutor(),
        task_store=InMemoryTaskStore(),
    )

    server = A2AStarletteApplication(
        agent_card=AGENT_CARD,
        http_handler=request_handler,
    )

    tasks: list[asyncio.Task] = []
    if enable_http:
        tasks.append(asyncio.create_task(run_http_server(server)))
    tasks.append(asyncio.create_task(run_transport(server)))

    await asyncio.gather(*tasks)


if __name__ == "__main__":
    try:
        asyncio.run(main(ENABLE_HTTP))
    except KeyboardInterrupt:
        logger.info("Shutting down gracefully.")
