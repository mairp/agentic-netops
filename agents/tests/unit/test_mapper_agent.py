from __future__ import annotations

import pytest

from provisioning.mapper.agent import MappingAgent


@pytest.mark.asyncio
async def test_unknown_construct_refusal_lists_constructs():
    prompt = "Please build a foo-service between leaf01 wan1 and leaf02 wan1 for tenant acme"
    _message, interpretation = await MappingAgent().ainvoke(prompt)
    # Mapping returns an Interpretation even for rejections; terminal flag prevents routing
    assert "constructs: vlan, mac-vrf, ip-vrf, acl" in interpretation.unsupported_properties
