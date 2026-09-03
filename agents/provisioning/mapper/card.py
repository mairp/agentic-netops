from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentSkill,
)

# Ported from the subject's ``agents/provisioning/mapper/card.py``. The card
# id is the routable ``org/namespace/local_name`` form that
# ``A2AProtocol.create_agent_topic`` derives the SLIM topic from (FR-023,
# contracts/a2a-transport.md; the subject's own comment states the
# requirement). The installed a2a-sdk 0.3.0 AgentCard has no ``id`` field —
# it is carried as a tolerated extra and read by the topic factory
# (verified on the pinned SDK).

AGENT_SKILL = AgentSkill(
    id="map_network_request",
    name="Map Network Service Request",
    description="Extracts and structures technical parameters from a network service request.",
    tags=["network", "provisioning", "intent", "mapping"],
    examples=[
        "Deploy an L2VPN between Site-A and Site-B with 1Gbps",
        "Create a 500Mbps L3VPN between Paris and London",
        "Provision a VPLS for tenant ACME between two sites",
        "Map this request: deploy a VPN between New York and Boston at 300Mbps",
    ],
)

AGENT_CARD = AgentCard(
    name="Network Mapping Agent",
    # NOTE: id must be a valid routable name: org/namespace/local_name
    # This is used by A2AProtocol.create_agent_topic to build the topic.
    id="agentic-netops/provisioning/network-mapping",
    description="An AI agent that maps natural language network service requests into structured technical parameters.",
    url="",
    version="1.0.0",
    defaultInputModes=["text"],
    defaultOutputModes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[AGENT_SKILL],
    supportsAuthenticatedExtendedCard=False,
)
