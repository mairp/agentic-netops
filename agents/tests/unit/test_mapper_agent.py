from __future__ import annotations

from provisioning.mapper.agent import _parse_endpoints


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
