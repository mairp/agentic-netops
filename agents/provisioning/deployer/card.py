from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentSkill,
)

# Ported from the subject's ``agents/provisioning/deployer/card.py`` with the
# card id corrected to the routable ``org/namespace/local_name`` form (the
# subject's ``network-deployer-agent`` is NOT routable; FR-023 requires the
# topic derivation — contracts/a2a-transport.md).

DEPLOY_SERVICE_SKILL = AgentSkill(
    id="deploy_network_service",
    name="Deploy Network Service",
    description=(
        "Deploys a network service to the fabric using allocated technical "
        "parameters: submits the declarative Network and SRv6Service objects, "
        "watches convergence, and reports the outcome."
    ),
    tags=[
        "network",
        "provisioning",
        "deployer",
        "vlan",
        "mac-vrf",
        "ip-vrf",
        "acl",
        "connectivity",
        "deployment",
        "remove",
    ],
    examples=[
        "Deploy a mac-vrf service with allocated L2VNI and route targets.",
        "Provision a local vlan to the fabric from allocated parameters.",
        "Execute deployment for an ip-vrf with allocated L3VNI and RD/RT.",
        "Apply allocated construct parameters to the network infrastructure.",
    ],
)

AGENT_CARD = AgentCard(
    name="Network Deployer Agent",
    # NOTE: id must be a valid routable name: org/namespace/local_name
    id="agentic-netops/provisioning/network-deployer",
    description=(
        "An AI agent that deploys network services to the fabric using allocated "
        "technical parameters. Handles service provisioning, configuration deployment, "
        "and deployment status reporting."
    ),
    url="",  # Optional: add repo or service URL
    version="1.0.0",
    defaultInputModes=["text"],
    defaultOutputModes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[DEPLOY_SERVICE_SKILL],
    supportsAuthenticatedExtendedCard=False,
)
