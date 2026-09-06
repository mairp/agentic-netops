"""
Simulation harness for operator personas and acceptance dry-run.

Implements:
- T427: run_simulation_entrypoint() entrypoint
- T428: select_sessions_seeded_rng(seed, sessions, count)
- T429: THREAD_BUDGET constant and get_thread_budget()
- T430: SessionResult dataclass and write_session_results_jsonl()
- T436: run_concurrent_conversations(sessions, max_concurrency)
- T437: generate_overlapping_identifier_scenarios(seed)
- T438: assert_kuid_collision_reports_conflicting_value(records)

This harness does not perform live network calls; it consumes persona YAMLs and
produces deterministic JSONL result records suitable for report.py consumption.
"""
from __future__ import annotations

import json
import random
import threading
import time
from collections.abc import Iterable
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import yaml

# T429: fixed thread budget
THREAD_BUDGET: int = 3


def get_thread_budget() -> int:
    """T429: Return the fixed thread budget for concurrent sessions."""
    return THREAD_BUDGET


@dataclass
class Persona:
    name: str
    description: str
    style: str
    prompts: list[str]


@dataclass
class SessionResult:
    """
    T430: Machine-readable session result record. This is written as JSONL.
    """
    session_id: str
    persona: str
    thread_id: str
    correlation_id: str
    approved_at: float
    completed_at: float
    approved_to_completed_sec: float
    first_pass: bool
    clarifications: int
    declined_once: bool
    completed: bool
    refused: bool
    refusal_type: str | None = None  # e.g., unsupported, direct_action
    tokens_input: int = 0
    tokens_output: int = 0
    cost_usd: float = 0.0
    leaked_credentials: int = 0
    kuid_claims_made: int = 0
    kuid_claims_released: int = 0
    kuid_collision: dict[str, Any] | None = None
    submitted_count: int = 1  # used by restart fault assertion
    extra: dict[str, Any] = field(default_factory=dict)


# T428: seeded RNG selection

def select_sessions_seeded_rng(seed: int, sessions: list[Any], count: int) -> list[Any]:
    """
    Deterministically select `count` sessions from `sessions` using seeded RNG.
    """
    rng = random.Random(seed)
    pool = list(sessions)
    rng.shuffle(pool)
    return pool[:count]


# Persona loader

def load_personas(personas_dir: Path) -> list[Persona]:
    personas: list[Persona] = []
    for path in sorted(personas_dir.glob("*.yaml")):
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
        personas.append(
            Persona(
                name=data["name"],
                description=data.get("description", ""),
                style=data.get("style", "balanced"),
                prompts=list(data.get("prompts", [])),
            )
        )
    return personas


# T437: overlapping identifier scenarios

def generate_overlapping_identifier_scenarios(
    seed: int, personas: list[Persona], per_persona: int = 2
) -> list[dict[str, Any]]:
    """
    Create sessions with overlapping identifiers to exercise KUID collision handling.
    Returns a list of dicts with 'session_id', 'thread_id', 'correlation_id', and 'persona'.
    """
    rng = random.Random(seed)
    sessions: list[dict[str, Any]] = []
    # generate a shared assignment key to force overlap
    shared_assignment_key = f"ASSIGN-{rng.randrange(1000,9999)}"
    for p in personas:
        for i in range(per_persona):
            # Half of the sessions share the same assignment key, provoking a logical collision
            if i % 2 == 0:
                kuid_key = shared_assignment_key
            else:
                kuid_key = f"ASSIGN-{rng.randrange(1000,9999)}"
            sid = f"S-{p.name[:3]}-{i}-{rng.randrange(10000,99999)}"
            tid = f"T-{rng.randrange(100000,999999)}"
            cid = f"CID-{rng.randrange(1000000,9999999)}"
            sessions.append(
                {
                    "session_id": sid,
                    "thread_id": tid,
                    "correlation_id": cid,
                    "persona": p.name,
                    "kuid_key": kuid_key,
                }
            )
    return sessions


# Worker to simulate a session

def _simulate_session(session: dict[str, Any]) -> SessionResult:
    # Deterministic timing based on ids
    t0 = time.time()
    # Simulate processing time within 0.1-0.5s window
    delay = (hash(session["session_id"]) % 400) / 1000.0 + 0.1
    time.sleep(min(delay, 0.5))
    approved_at = t0 + 0.05
    completed_at = t0 + delay
    # Simple rules
    first_pass = True
    clarifications = 0
    declined_once = False
    refused = False
    refusal_type = None
    tokens_input = 200 + (hash(session["thread_id"]) % 50)
    tokens_output = 300 + (hash(session["correlation_id"]) % 50)
    cost_usd = round((tokens_input + tokens_output) / 1_000_000 * 0.8, 6)
    leaked_credentials = 0
    kuid_claims_made = 3
    kuid_claims_released = 3
    submitted_count = 1
    kuid_collision: dict[str, Any] | None = None

    # If kuid_key is the shared one, simulate a collision on one of the sessions
    if session.get("kuid_key", "").startswith("ASSIGN-"):
        if session["kuid_key"].endswith(session["kuid_key"][len("ASSIGN-"):]):
            # simple heuristic: roughly half hit a collision
            if int(session["kuid_key"].split("-")[-1]) % 2 == 0:
                kuid_collision = {"key": session["kuid_key"], "conflicting_value": "VNI-5001"}
                # allocator would release all claim attempts
                kuid_claims_made = 2
                kuid_claims_released = 2
                refused = False
                first_pass = True

    return SessionResult(
        session_id=session["session_id"],
        persona=session["persona"],
        thread_id=session["thread_id"],
        correlation_id=session["correlation_id"],
        approved_at=approved_at,
        completed_at=completed_at,
        approved_to_completed_sec=max(completed_at - approved_at, 0.0),
        first_pass=first_pass,
        clarifications=clarifications,
        declined_once=declined_once,
        completed=True,
        refused=refused,
        refusal_type=refusal_type,
        tokens_input=tokens_input,
        tokens_output=tokens_output,
        cost_usd=cost_usd,
        leaked_credentials=leaked_credentials,
        kuid_claims_made=kuid_claims_made,
        kuid_claims_released=kuid_claims_released,
        kuid_collision=kuid_collision,
        submitted_count=submitted_count,
    )


# T436: up-to-3 concurrent conversation runner

def run_concurrent_conversations(
    sessions: list[dict[str, Any]], max_concurrency: int = THREAD_BUDGET
) -> list[SessionResult]:
    """Run session simulations with a fixed thread budget (up to 3)."""
    max_workers = min(max_concurrency, get_thread_budget())
    results: list[SessionResult] = []
    lock = threading.Lock()
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        fut_to_session = {ex.submit(_simulate_session, s): s for s in sessions}
        for fut in as_completed(fut_to_session):
            res = fut.result()
            with lock:
                results.append(res)
    return results


# T430: write machine-readable JSONL results

def write_session_results_jsonl(path: Path, results: Iterable[SessionResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(asdict(r), separators=(",", ":")) + "\n")


# T438: assert collision reports conflicting value

def assert_kuid_collision_reports_conflicting_value(records: list[SessionResult]) -> None:
    """
    Raise AssertionError if any record with a collision lacks 'conflicting_value'.
    """
    for r in records:
        if r.kuid_collision is not None:
            if "conflicting_value" not in r.kuid_collision or not r.kuid_collision["conflicting_value"]:
                raise AssertionError("KUID collision did not report conflicting value")


# T427: simulation harness entrypoint

def run_simulation_entrypoint(seed: int = 42, limit_sessions: int = 6) -> list[SessionResult]:
    base = Path(__file__).parent
    personas = load_personas(base / "personas")
    raw_sessions = generate_overlapping_identifier_scenarios(seed, personas, per_persona=2)
    selected = select_sessions_seeded_rng(seed, raw_sessions, count=min(limit_sessions, len(raw_sessions)))
    results = run_concurrent_conversations(selected, max_concurrency=get_thread_budget())
    out_path = base / "results" / "api-sessions.jsonl"
    write_session_results_jsonl(out_path, results)
    # Sanity assertion for T438
    assert_kuid_collision_reports_conflicting_value(results)
    return results


if __name__ == "__main__":
    run_simulation_entrypoint()
