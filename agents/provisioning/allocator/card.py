from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentSkill,
)

# Ported from the subject's ``agents/provisioning/allocator/card.py`` with the
# card id corrected to the routable ``org/namespace/local_name`` form (the
# subject's ``network-allocator-agent`` is NOT routable; FR-023 requires the
# topic derivation — contracts/a2a-transport.md).

ALLOCATE_SERVICE_SKILL = AgentSkill(
    id="allocate_network_service",
    name="Allocate Network Service Parameters",
    description=(
        "Allocates concrete technical parameters (VLANs, VRFs, interfaces, "
        "route-targets, QoS profiles, etc.) for a mapped network service request."
    ),
    tags=[
        "network",
        "provisioning",
        "allocator",
        "l2vpn",
        "l3vpn",
        "connectivity",
    ],
    examples=[
        "Allocate parameters for an L2VPN between Site-A and Site-B with 1Gbps.",
        "Assign VLANs and interfaces for a mapped service request.",
        "Generate route-targets and VRFs for a new VPN service.",
        "Allocate network resources for an enterprise WAN service.",
        "Produce technical configuration parameters from a mapped request.",
    ],
)

AGENT_CARD = AgentCard(
    name="Network Allocator Agent",
    # NOTE: id must be a valid routable name: org/namespace/local_name
    id="agentic-netops/provisioning/network-allocator",
    description=(
        "An AI agent that allocates concrete technical network resources for "
        "mapped service requests, such as VLAN IDs, VRFs, interfaces, route-targets, "
        "and QoS profiles, before provisioning."
    ),
    url="",  # Optional: add repo or service URL
    version="1.0.0",
    defaultInputModes=["text"],
    defaultOutputModes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[ALLOCATE_SERVICE_SKILL],
    supportsAuthenticatedExtendedCard=False,
)
