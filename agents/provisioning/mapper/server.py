"""Mapper worker server (T082 skeleton, completed by US3 T142/T145/T148).

Ports the subject's ``agents/provisioning/mapper/server.py``
(``A2AStarletteApplication`` + ``DefaultRequestHandler`` +
``InMemoryTaskStore`` + the ``/v1/health`` route, uvicorn on port 9092)
and completes the US3 phase wiring:

* **T142 — SLIM-only transport validation**: the worker refuses to start
  (or to register) on any transport other than ``SLIM`` — the same hard
  requirement the supervisor's call helpers carry (contracts/
  a2a-transport.md, research.md Decision 2). Not a soft default.
* **T145 — transport registration** over ``TRANSPORT_SERVER_ENDPOINT``
  (the long variable name, port 46357): an ``AgntcyFactory`` transport
  session whose name is the topic derived from the card's routable id
  via ``A2AProtocol.create_agent_topic`` — discovery is card-derived,
  never a hardcoded topic list (T141).
* **T148 — transport authentication failure handling** (FR-024): a
  registration refused for authentication reasons is surfaced as
  :class:`common.exceptions.AuthError` — never swallowed into a generic
  stage failure — and the ``/v1/health`` probe reports 503 with an
  explicit ``auth`` status.
* **Deep liveness (US3)**: ``/v1/health`` creates a real A2A session over
  SLIM (the subject's probe), so "alive" means the worker can actually be
  reached, not merely that the process is up.
"""

from __future__ import annotations

import asyncio
import logging

from a2a.server.apps import A2AStarletteApplication
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from agntcy_app_sdk.app_sessions import AppContainer
from agntcy_app_sdk.factory import AgntcyFactory
from agntcy_app_sdk.semantic.a2a.protocol import A2AProtocol
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from starlette.middleware.cors import CORSMiddleware
from starlette.routing import Route
from uvicorn import Config, Server

from common.exceptions import AuthError
from config.config import DEFAULT_MESSAGE_TRANSPORT, ENABLE_HTTP, TRANSPORT_SERVER_ENDPOINT
from provisioning.mapper.agent_executor import MappingAgentExecutor
from provisioning.mapper.card import AGENT_CARD

factory = AgntcyFactory("devnet.network_mapping", enable_tracing=True)

logger = logging.getLogger("devnet.network_mapping.server")
logging.basicConfig(level=logging.INFO)

WORKER = "mapper"
PORT = 9092  # subject's port, kept (contracts/supervisor-http.md)
LIVENESS_SESSION_TIMEOUT_SECONDS = 15

# Deep-liveness source of truth (US3): run_transport sets REGISTRATION_OK
# once the transport session is actually registered with the SLIM gateway;
# REGISTRATION_STATUS records the classified outcome ("registered",
# "auth", "timeout", "error", "starting") so /v1/health names the state.
# A fresh create_client per probe would race the gateway's card
# resolution and flake; observing the real registration state is the
# honest deep check — the worker is only "alive" if it registered.
REGISTRATION_OK = asyncio.Event()
REGISTRATION_STATUS = "starting"

# Substrings that identify a transport rejection as an authentication
# failure (FR-024: the gateway is TLS with client-certificate verification
# plus a generated PASSWORD). Matched case-insensitively against the
# transport error text; anything else is a generic transport error.
_AUTH_FAILURE_MARKERS = (
    "unauthenticated",
    "unauthorized",
    "auth",
    "401",
    "403",
    "permission denied",
    "certificate",
    "tls",
    "password",
)


# ---------------- SLIM-only validation (T142) ----------------


def require_slim(transport_type: str) -> None:
    """T142 — refuse any transport other than SLIM, loudly.

    The subject's hard requirement, applied to the worker side: a worker
    started against a non-SLIM transport would register a topic nothing
    else can reach. This is a startup configuration error, not a fallback
    condition.
    """
    if transport_type != "SLIM":
        raise ValueError("Only SLIM transport is supported for provisioning agents.")


def classify_transport_error(exc: BaseException) -> str:
    """T148 — classify a transport failure as ``auth`` or ``error``.

    An authentication refusal (FR-024) must be distinguishable from a
    generic connectivity failure, both in the logs and in the ``/v1/health``
    response the supervisor's deep readiness probe reads.
    """
    text = str(exc).lower()
    if any(marker in text for marker in _AUTH_FAILURE_MARKERS):
        return "auth"
    return "error"


# ---------------- HEALTH ----------------


async def liveness_probe(request) -> JSONResponse:
    """Deep liveness (US3): report whether this worker actually REGISTERED
    with the SLIM gateway over ``TRANSPORT_SERVER_ENDPOINT`` (T145). 200
    ``alive`` only when the transport registration succeeded; 503 with
    ``status=auth`` when the gateway refused the worker's credentials
    (T148), 503 with ``status=timeout``/``status=error``/``status=starting``
    naming every other state."""
    if REGISTRATION_OK.is_set():
        return JSONResponse(
            {
                "status": "alive",
                "worker": WORKER,
                "registration": REGISTRATION_STATUS,
                "transport": DEFAULT_MESSAGE_TRANSPORT,
                "endpoint": TRANSPORT_SERVER_ENDPOINT,
            }
        )
    status = REGISTRATION_STATUS
    detail = {
        "auth": "transport authentication failed (FR-024): the gateway refused this worker's credentials",
        "timeout": "timeout registering with the SLIM gateway",
        "error": "transport registration failed",
        "starting": "transport registration has not completed yet",
    }.get(status, "transport registration failed")
    if status == "auth":
        logger.error("transport authentication failed for %s (FR-024)", WORKER)
    return JSONResponse(
        {"status": status, "worker": WORKER, "error": detail},
        status_code=503,
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
    # Trivial liveness (process up): mirrors the supervisor's /health so a
    # transport outage degrades /v1/health readiness instead of killing the
    # container (a downed worker is *named*, not crashed away).
    app_.router.routes.append(
        Route("/health", lambda _r: JSONResponse({"status": "ok", "worker": WORKER}), methods=["GET"])
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
    """T145 — register this worker with the SLIM gateway over
    ``TRANSPORT_SERVER_ENDPOINT`` (AgntcyFactory transport + AppContainer
    session, as in the subject's ``run_transport``).

    The session name is the card-derived topic (``A2AProtocol.
    create_agent_topic(AGENT_CARD)``) — discovery follows the card, there
    is no hardcoded worker topic list (T141). An authentication refusal
    (FR-024) is re-raised as :class:`AuthError` (T148) so the failure is
    named as such everywhere it surfaces.
    """
    require_slim(DEFAULT_MESSAGE_TRANSPORT)  # T142 — SLIM-only, hard requirement
    global REGISTRATION_STATUS
    app_session = None
    try:
        # Registration name MUST be the SDK-sanitized topic (spaces ->
        # underscores): clients resolve the card topic through
        # SLIMTransport.sanitize_topic, and a raw-space local_name never
        # matches the route (the gateway answers "no matching found").
        topic = A2AProtocol.create_agent_topic(AGENT_CARD).replace(" ", "_")
        transport = factory.create_transport(
            DEFAULT_MESSAGE_TRANSPORT,
            endpoint=TRANSPORT_SERVER_ENDPOINT,
            name=f"default/default/{topic}",
        )
        app_session = factory.create_app_session(max_sessions=1)
        app_session.add_app_container(
            "group_session",
            AppContainer(server, transport=transport),
        )
        await app_session.start_session("group_session")
        REGISTRATION_OK.set()  # deep liveness (US3): the registration is real
        REGISTRATION_STATUS = "registered"
        logger.info(
            "%s registered with SLIM at %s (topic %s)", WORKER, TRANSPORT_SERVER_ENDPOINT, topic
        )
    except AuthError:
        # T148 — already typed; propagate so the process fails naming the cause.
        REGISTRATION_STATUS = "auth"
        logger.error("SLIM refused %s's credentials (FR-024); refusing to serve", WORKER)
        raise
    except Exception as exc:  # noqa: BLE001 - classify, then fail with the type
        kind = classify_transport_error(exc)
        REGISTRATION_STATUS = kind  # deep liveness (US3) names the failure
        logger.error("transport error (%s) for %s: %s", kind, WORKER, exc)
        if app_session is not None:
            await app_session.stop_all_sessions()
        if kind == "auth":
            raise AuthError(f"SLIM gateway rejected {WORKER}: {exc}") from exc
        raise


# ---------------- MAIN ----------------


async def main(enable_http: bool) -> None:
    require_slim(DEFAULT_MESSAGE_TRANSPORT)  # T142 — refuse a non-SLIM startup

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
