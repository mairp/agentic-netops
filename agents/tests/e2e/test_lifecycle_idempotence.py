from __future__ import annotations

import os
import subprocess

import pytest

pytestmark = pytest.mark.e2e


def _run(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def test_provision_with_intent_tier_idempotent():
    """T386 — Running scripts/provision.sh --with-intent-tier twice should converge without error.

    This test asserts exit code 0 for both runs. It does not require an existing cluster; the
    provision script is responsible for ensuring idempotent bring-up.
    """
    script = os.path.join(os.path.dirname(__file__), "..", "..", "..", "scripts", "provision.sh")
    script = os.path.abspath(script)
    assert os.path.exists(script), f"provision script not found: {script}"
    rc1, out1, err1 = _run([script, "--with-intent-tier"])  # first run
    rc2, out2, err2 = _run([script, "--with-intent-tier"])  # second run (idempotence)
    assert rc1 == 0, f"first provision run failed: {err1}\n{out1}"
    assert rc2 == 0, f"second provision run failed (not idempotent): {err2}\n{out2}"


def test_off_purge_intent_tier_noop_on_second_run():
    """T387 — Running scripts/off.sh --purge-intent-tier twice should be a safe no-op on the second run."""
    script = os.path.join(os.path.dirname(__file__), "..", "..", "..", "scripts", "off.sh")
    script = os.path.abspath(script)
    assert os.path.exists(script), f"off script not found: {script}"
    rc1, out1, err1 = _run([script, "--purge-intent-tier"])  # first purge
    rc2, out2, err2 = _run([script, "--purge-intent-tier"])  # second purge (no-op)
    assert rc1 == 0, f"first purge run failed: {err1}\n{out1}"
    assert rc2 == 0, f"second purge run failed (not a no-op): {err2}\n{out2}"
