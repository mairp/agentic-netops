"""T007 — interim SRv6 refusals (FR-003, FR-015, SC-008; plan 1-04).

Every case of ``unsupported/srv6_transport.yaml`` must yield a TERMINAL
refusal that names SRv6 (refusal R1, contracts/operator-phrasings.md §3) and
must never produce a ``vlan``, ``mac-vrf``, ``ip-vrf`` or ``acl``
interpretation: an SRv6 qualifier decides the transport, so a legacy service
name beside it ("SRv6 L3VPN between ...", migration alias) is never enough
to select a VXLAN construct.

Asserted at two levels:

1. the deterministic mapper flags the SRv6 transport itself
   (``srv6Transport`` in ``unsupported_properties`` — a terminal result, so
   no DataPart is emitted and nothing downstream is routed);
2. the full graph run reaches FAILED with the R1 refusal text and an audited
   ``refuse`` event, and no interpretation is accepted for confirmation.

Until the mapper recognises SRv6 (T008), these phrasings fall through to the
l3vpn/evpn/vrf patterns and map to VXLAN constructs — this test fails on
exactly that, which is its pre-implementation state (plan 1-04).
"""
from __future__ import annotations

import asyncio
import json

import yaml

from provisioning.mapper.agent import MappingAgent
from tests.corpus.adversarial.runner import (
    AdversarialCase,
    _check_common,
    _check_refusal,
    _last_ai_message,
    _run_once,
)
from tests.corpus.phrasings.runner import UNSUPPORTED_DIR

SRV6_CORPUS = UNSUPPORTED_DIR / "srv6_transport.yaml"
# SC-008: the constructs an SRv6 request must never be mapped to while the
# interim refusal R1 is in force.
SUPPORTED_CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")
R1_FRAGMENT = "not provisioned as a VXLAN service"


def load_srv6_cases() -> list[AdversarialCase]:
    data = yaml.safe_load(SRV6_CORPUS.read_text(encoding="utf-8"))
    assert data.get("property") == "srv6Transport", "corpus drift: expected the srv6Transport property"
    return [
        AdversarialCase(
            id=raw["id"],
            category=data.get("category", "srv6_transport"),
            text=raw["text"],
            expect=raw.get("expect", "refusal"),
            # the refusal must name SRv6 (T006: "a refusal that names SRv6")
            reason_contains=("SRv6",),
            assert_no_worker_calls=True,
        )
        for raw in data.get("cases", [])
    ]


def test_srv6_phrasings_refuse_naming_srv6():
    failures: list[str] = []
    agent = MappingAgent()
    for case in load_srv6_cases():
        v: list[str] = []

        # --- Level 1: the mapper flags the transport, terminally -----------
        _msg, interp = asyncio.run(agent.ainvoke(case.text))
        if "srv6Transport" not in interp.unsupported_properties:
            v.append(
                "mapper did not flag srv6Transport; "
                f"unsupported={interp.unsupported_properties!r} service_type={interp.service_type!r}"
            )
        if interp.missing_fields:
            v.append(
                f"SRv6 result is not terminal: missing_fields={interp.missing_fields!r} "
                "(a terminal unsupported result never also clarifies)"
            )

        # --- Level 2: the full graph refuses terminally naming SRv6 --------
        result = asyncio.run(_run_once(case, None, case.text, []))
        _check_common(result)
        _check_refusal(result)
        state = result.state
        if "SRv6" not in (state.get("refusal_reason") or ""):
            v.append(f"refusal_reason {state.get('refusal_reason')!r} does not name SRv6")
        if R1_FRAGMENT not in _last_ai_message(state):
            v.append(
                "operator-facing refusal is not R1 "
                "(contracts/operator-phrasings.md §3: 'not provisioned as a VXLAN service')"
            )
        # ...and never a VXLAN-construct interpretation (SC-008)
        mapped = state.get("mapped_parameters")
        if mapped:
            st = ""
            try:
                st = str(json.loads(mapped).get("service_type") or "")
            except Exception:  # noqa: BLE001
                st = "?"
            v.append(
                f"an interpretation was accepted for an SRv6 request "
                f"(service_type={st!r}, pending_action={state.get('pending_action')!r})"
            )
            if st in SUPPORTED_CONSTRUCTS:
                v.append(f"the SRv6 phrasing mapped to the VXLAN construct {st!r}")
        if v:
            failures.append(f"{case.id}: " + "; ".join(v))
    assert not failures, (
        "SRv6 phrasings must refuse terminally naming SRv6 and never map to a "
        "VXLAN construct (FR-003, SC-008):\n  " + "\n  ".join(failures)
    )
