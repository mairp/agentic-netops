from __future__ import annotations

from provisioning.mapper.agent import MappingAgent, _parse_endpoints, _parse_prefixes


def test_parse_endpoints_stops_before_tenant_clause():
    endpoints = _parse_endpoints(
        "Provision a point-to-point 1G VPWS between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme"
    )

    assert [endpoint.model_dump(mode="json") for endpoint in endpoints] == [
        {"site_or_node": "leaf01", "attachment": "ethernet1", "vlan": None},
        {"site_or_node": "leaf02", "attachment": "ethernet2", "vlan": None},
    ]


def test_parse_endpoints_applies_global_trailing_vlan_to_both_endpoints():
    endpoints = _parse_endpoints(
        "Create a full-mesh VPLS between leaf01 ethernet3 and leaf02 ethernet4 for tenant blue vlan 100"
    )

    assert [endpoint.model_dump(mode="json") for endpoint in endpoints] == [
        {"site_or_node": "leaf01", "attachment": "ethernet3", "vlan": 100},
        {"site_or_node": "leaf02", "attachment": "ethernet4", "vlan": 100},
    ]


def test_parse_attach_attachment_on_node_wording():
    endpoints = _parse_endpoints(
        "Attach wan1 on leaf01 and wan1 on leaf02. Allocate the identifiers automatically."
    )

    assert [endpoint.model_dump(mode="json") for endpoint in endpoints] == [
        {"site_or_node": "leaf01", "attachment": "wan1", "vlan": None},
        {"site_or_node": "leaf02", "attachment": "wan1", "vlan": None},
    ]


def test_parse_between_endpoints_stops_at_next_instruction():
    endpoints = _parse_endpoints(
        "Deploy an L3VPN between leaf01 wan1 and leaf02 wan1. "
        "Allocate the L3 VNI and route targets automatically."
    )

    assert [endpoint.model_dump(mode="json") for endpoint in endpoints] == [
        {"site_or_node": "leaf01", "attachment": "wan1", "vlan": None},
        {"site_or_node": "leaf02", "attachment": "wan1", "vlan": None},
    ]


def test_parse_dotted_attachment_name_is_not_a_sentence_boundary():
    endpoints = _parse_endpoints(
        "Create a VPWS between leaf01 ethernet1.100 and leaf02 ethernet2.100 for tenant acme"
    )

    assert [endpoint.attachment for endpoint in endpoints] == ["ethernet1.100", "ethernet2.100"]


def test_parse_requested_ip_prefixes():
    assert _parse_prefixes("Use IPv4 prefix 10.99.18.0/24 and IPv6 prefix 2001:db8:18::/64") == (
        ["10.99.18.0/24"],
        ["2001:db8:18::/64"],
    )


async def test_full_ui_validation_prompt_maps_without_trailing_sentence_leak():
    prompt = (
        "Deploy an L3VPN service for tenant validation-test with IPv4 prefix 10.99.18.0/24 "
        "between leaf01 wan1 and leaf02 wan1. Allocate the L3 VNI, route distinguisher, and "
        "import/export route targets automatically. Show the proposed configuration and wait "
        "for my approval before deployment."
    )

    _message, interpretation = await MappingAgent().ainvoke(prompt)

    assert interpretation.missing_fields == []
    assert interpretation.ipv4_prefixes == ["10.99.18.0/24"]
    assert [(endpoint.site_or_node, endpoint.attachment) for endpoint in interpretation.endpoints] == [
        ("leaf01", "wan1"),
        ("leaf02", "wan1"),
    ]


async def test_the_prompt_that_submitted_an_attachment_called_VNI():
    """The failure the operator actually hit.

    "... and leaf02 wan1. Allocate the L3 VNI with ..." used to parse into
    attachment "VNI" on a node called "leaf02 wan1. Allocate the L3". That was
    submitted to the cluster and only then rejected by the fabric, leaving a
    stranded Network behind.
    """

    prompt = (
        "Create an L3VPN between leaf01 wan1 and leaf02 wan1. Allocate the L3 VNI "
        "with prefix 10.99.20.0/24 for tenant acme"
    )

    _message, interpretation = await MappingAgent().ainvoke(prompt)

    assert [(e.site_or_node, e.attachment) for e in interpretation.endpoints] == [
        ("leaf01", "wan1"),
        ("leaf02", "wan1"),
    ]
    assert interpretation.missing_fields == []


async def test_every_service_type_maps_from_ordinary_phrasing():
    cases = [
        ("L3VPN", "Please build a layer3 vpn for tenant orange between wan1 on leaf01 and wan1 on leaf02."),
        ("VPLS", "Provision a VPLS between ethernet1 on leaf01 and ethernet1 on leaf02 for tenant blue on vlan 300"),
        ("VPWS", "Create a VPWS point-to-point between leaf01 ethernet1 and leaf02 ethernet1 for tenant green"),
        ("IRB", "Deploy an IRB service between ethernet1 on leaf01 and ethernet1 on leaf02 for tenant red with prefix 10.40.0.0/24"),
    ]
    agent = MappingAgent()
    for expected_type, prompt in cases:
        _message, interpretation = await agent.ainvoke(prompt)
        assert interpretation.service_type.value == expected_type, prompt
        assert interpretation.missing_fields == [], prompt
        assert [(e.site_or_node, e.attachment) for e in interpretation.endpoints] == [
            ("leaf01", "ethernet1" if expected_type != "L3VPN" else "wan1"),
            ("leaf02", "ethernet1" if expected_type != "L3VPN" else "wan1"),
        ], prompt


async def test_trailing_commentary_after_the_node_is_not_part_of_its_name():
    _message, interpretation = await MappingAgent().ainvoke(
        "attach Ethernet1 on Leaf01 and Ethernet1 on Leaf02 as an l2vpn for tenant purple"
    )
    assert [(e.site_or_node, e.attachment) for e in interpretation.endpoints] == [
        ("Leaf01", "Ethernet1"),
        ("Leaf02", "Ethernet1"),
    ]


async def test_no_endpoint_name_ever_carries_whitespace():
    """Node and attachment names are single tokens at every site.

    The mapper cannot know which words are real device names — the site
    inventory in the Go translator refuses names this fabric does not have,
    before anything is submitted. What the mapper CAN guarantee is that it
    never emits a multi-word name, which is the shape that reached the fabric
    as ``attachment "VNI"`` on node ``"leaf02 wan1. Allocate the L3"``.
    """

    prompts = [
        "Create an L3VPN between leaf01 wan1 and leaf02 wan1. Allocate the L3 VNI with prefix 10.9.0.0/24 for tenant acme",
        "attach Ethernet1 on Leaf01 and Ethernet1 on Leaf02 as an l2vpn for tenant purple",
        "Set up an l2vpn for tenant grey between the usual place and the other one",
        "Build a vpls between leaf01 ethernet1 and leaf02 ethernet1, then tell me the vlan, for tenant grey",
    ]
    agent = MappingAgent()
    for prompt in prompts:
        _message, interpretation = await agent.ainvoke(prompt)
        for endpoint in interpretation.endpoints:
            assert " " not in endpoint.site_or_node, (prompt, endpoint)
            assert " " not in endpoint.attachment, (prompt, endpoint)
