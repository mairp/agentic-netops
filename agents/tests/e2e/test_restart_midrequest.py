from __future__ import annotations

import os
import secrets
import tempfile

import pytest
from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import ProvisioningGraph
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport


@pytest.mark.asyncio
async def test_supervisor_restart_setup_and_resume(monkeypatch):
    """T371/T372 — A thread mid-request resumes after a 'restart' (new graph instance).

    We bind the SQLite checkpointer to a real file, run the first pass to reach
    MAPPED with a pending first confirmation, then construct a new graph instance
    against the same DB path and continue the thread by sending 'confirm'.
    """
    # Bind the checkpointer to a temp sqlite file (durable across graph instances)
    db_fd, db_path = tempfile.mkstemp(prefix="supervisor-checkpoints-", suffix=".sqlite")
    os.close(db_fd)
    monkeypatch.setenv("SUPERVISOR_CHECKPOINT_DB", db_path)
    # Also patch the module-level path used by the graph (evaluated at import)
    import supervisors.provisioning.graph.graph as graph_mod
    graph_mod.CHECKPOINT_DB_PATH = db_path

    tr = StubTransport()
    llm = StubClassifierLLM()
    thread_id = f"restart-{secrets.token_hex(8)}"

    # First pass: reach MAPPED awaiting confirm_1
    g1 = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        state1 = await g1.ainvoke(
            {
                "messages": [
                    {
                        "type": "human",
                        "content": "provision a VPWS between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 100",
                    }
                ],
            },
            config={"configurable": {"thread_id": thread_id}},
        )
        assert state1.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value
        assert state1.get("awaiting_confirmation") is True
        assert state1.get("pending_action") == "confirm_1"
    finally:
        await g1.close()

    # 'Restart': New graph instance with the same DB path; continue the thread
    g2 = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        state2 = await g2.ainvoke(
            {"messages": [{"type": "human", "content": "confirm"}]},
            config={"configurable": {"thread_id": thread_id}},
        )
        assert state2.get("workflow_status") == NetworkProvisioningStatus.ALLOCATED.value
        assert state2.get("awaiting_confirmation") is True
        assert state2.get("pending_action") == "confirm_2"
    finally:
        await g2.close()


@pytest.mark.asyncio
async def test_post_restart_no_double_submit(monkeypatch):
    """T373 — After resume, deployment happens once (no double submit).

    Confirming twice across a restart results in exactly one deployer call and a
    single submission report.
    """
    db_fd, db_path = tempfile.mkstemp(prefix="supervisor-checkpoints-", suffix=".sqlite")
    os.close(db_fd)
    monkeypatch.setenv("SUPERVISOR_CHECKPOINT_DB", db_path)

    tr = StubTransport()
    llm = StubClassifierLLM()
    thread_id = f"restart-{secrets.token_hex(8)}"

    # First pass -> MAPPED
    g1 = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        await g1.ainvoke(
            {
                "messages": [
                    {
                        "type": "human",
                        "content": "provision a VPWS between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 100",
                    }
                ],
            },
            config={"configurable": {"thread_id": thread_id}},
        )
    finally:
        await g1.close()

    # Resume and confirm twice -> PROVISIONING, exactly one deployer call
    g2 = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        state = await g2.ainvoke(
            {"messages": [{"type": "human", "content": "confirm"}]},
            config={"configurable": {"thread_id": thread_id}},
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.ALLOCATED.value
        state = await g2.ainvoke(
            {"messages": [{"type": "human", "content": "confirm"}]},
            config={"configurable": {"thread_id": thread_id}},
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.PROVISIONING.value
        # Deployer is called exactly once across the resume path
        deployer_calls = [w for (w, _txt) in tr.calls if w == "deployer"]
        assert len(deployer_calls) == 1
    finally:
        await g2.close()
