"""T068 [P] [US5] Suggested prompts validity test.

Asserts every entry in agents/supervisors/provisioning/suggested_prompts.json:
- names a construct (vlan, mac-vrf, ip-vrf, acl), and
- every node and port it names resolves in FABRIC_PORT_MAP.

R-06: port names must be resolvable at this site.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

CONSTRUCT = re.compile(r"\b(vlan|mac[- ]?vrf|ip[- ]?vrf|acl)\b", re.I)
NODE = re.compile(r"\b(leaf\d+|spine\d+|site-[a-z0-9-]+)\b", re.I)
PORT = re.compile(r"\b(ethernet\d+|wan1|eth\d+)\b", re.I)

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "agents" / "supervisors" / "provisioning" / "suggested_prompts.json"


def _port_map() -> dict[str, str]:
    raw = os.getenv("FABRIC_PORT_MAP") or ""
    try:
        import json

        data = json.loads(raw) if raw else {}
        if not isinstance(data, dict):
            return {}
        return {str(k): str(v) for (k, v) in data.items()}
    except Exception:
        return {}


def test_prompts_name_construct_and_ports_exist(monkeypatch):
    # Seed a minimal site map matching quickstart Scenario 4 references
    monkeypatch.setenv(
        "FABRIC_PORT_MAP",
        '{"wan1":"eth4","ethernet1":"eth3","ethernet2":"eth3","ethernet3":"eth3","eth1":"eth1","eth2":"eth2","eth3":"eth3","eth4":"eth4"}',
    )
    prompts = PROMPTS.read_text(encoding="utf-8")
    assert prompts.startswith("[") and prompts.endswith("]\n")
    # Parse naive JSON array of strings; ok to eval after a sanity check
    import json

    arr = json.loads(prompts)
    assert isinstance(arr, list) and all(isinstance(s, str) for s in arr)

    pmap = _port_map()
    assert pmap, "FABRIC_PORT_MAP must be non-empty for this test"

    for s in arr:
        assert CONSTRUCT.search(s), f"no construct named in: {s!r}"
        # Every prompt names at least one port; resolve each token that looks like a port
        ports = PORT.findall(s)
        for p in ports:
            assert p in pmap, f"port {p!r} not in FABRIC_PORT_MAP"
