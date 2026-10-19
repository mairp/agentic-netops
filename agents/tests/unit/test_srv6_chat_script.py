"""Static coverage for the integration chat driver (T503/T504).

``srv6_chat.sh`` drives a live cluster, so the unit suite cannot execute it
end to end. Like the repo's other driver coverage, it asserts honestly on
what a shell driver can be checked for without a cluster: the file exists and
is executable, the shell parses it, the usage path names its flags, and the
decline branch's end-state assertions are present in the script text.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

SCRIPT = (
    Path(__file__).resolve().parents[1] / "integration" / "srv6_chat.sh"
)


def test_script_exists_and_is_executable():
    assert SCRIPT.is_file(), f"missing driver: {SCRIPT}"
    assert os.access(SCRIPT, os.X_OK), f"driver is not executable: {SCRIPT}"


def test_script_parses():
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)


def test_usage_names_every_flag():
    proc = subprocess.run(
        ["bash", str(SCRIPT)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode != 0, "missing args must exit non-zero"
    usage = proc.stdout + proc.stderr
    for flag in ("--request", "--confirm", "--decline"):
        assert flag in usage, f"usage does not name {flag}"


def test_help_path_exits_zero_and_prints_usage():
    proc = subprocess.run(
        ["bash", str(SCRIPT), "--help"],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0
    for flag in ("--request", "--confirm", "--decline"):
        assert flag in proc.stdout + proc.stderr


def test_decline_branch_asserts_no_srv6_service_no_network_no_claim():
    text = SCRIPT.read_text(encoding="utf-8")
    # The objects the decline path must refuse to find...
    assert "srv6services.agentic-netops.io" in text
    assert "get networks -A" in text
    # ...and the KUID claim existence check (namespace + correlation-id label)
    assert "kuid-system" in text
    assert "correlation-id" in text
    # ...each checked under the decline branch and exiting non-zero on hit.
    decline_section = text.split("if (( DECLINE ))", 1)[1]
    assert "SRV6_OBJECT" in decline_section
    assert "NETWORK_OBJECT" in decline_section
    assert "CLAIMS_FOUND" in decline_section
    assert "exit 1" in decline_section


def test_script_takes_request_confirm_decline_flags():
    text = SCRIPT.read_text(encoding="utf-8")
    for flag in ("--request", "--confirm", "--decline"):
        assert flag in text, f"flag {flag} not parsed"
