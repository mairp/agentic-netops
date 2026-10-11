# Business adoption: Network Service Provisioning Agent

Date: 2026-09-06
Audience: executive review. Baselines are to be measured at the adopting site; no production figures exist yet.

## Use case

Network Service Provisioning Agent

The datacenter network underneath the Signature Cloud supports every workload hosted there: virtual machines, containers, databases and tenant applications. Today, giving a workload the network it needs is a ticket handled by a network engineer. With this agent, an operator states the need in plain language, for example "give tenant Initech a private network for its new application". The agent explains what it understood, asks the operator to confirm, and delivers the service on the network. It declares success only after checking that the service really works, keeps checking afterwards, and repairs it automatically if something changes underneath. Requests it cannot fulfil safely are declined with the reason before anything is touched.

It covers the everyday building blocks of cloud networking: isolated tenant networks, connectivity between racks and sites, and security filtering.

## Impact

- Service delivery moves from a ticket queue measured in days to a conversation measured in minutes.
- Network engineers are freed from routine provisioning for design, capacity and incident work.
- Configuration mistakes fall, because every change is checked and rehearsed before it is applied and undone automatically if it fails.
- Every change is recorded with who asked, what was asked, and what was verified, so audit evidence is produced as a by-product.
- Services stay correct after delivery, because the agent re-verifies them continuously and repairs drift before customers notice.

## Feasibility

Proven end to end in a lab that mirrors the Signature Cloud fabric, for every service type in scope. Adoption needs the site's inventory of network equipment, its numbering plans, and access to an approved language model through the existing gateway. The agent is built to be cautious: it acts only after operator confirmation, holds no device passwords, and has narrowly scoped permissions. The current build supports the fabric's switch platform; other vendors would need an adapter.

## Success metrics

Business outcomes

- Time from request to verified network service: current ticket cycle time (to measure) → target under 15 minutes.
- Routine requests delivered without manual engineer work: 0% today → target 80%+ within six months.
- Incidents caused by network configuration errors: current rate (to measure) → target reduction of 50%+.
- Changes that fail or must be undone: current rate (to measure) → target under 2 per 100.
- Engineer hours spent on routine provisioning: current (to measure) → target reduction of 70%+.
- Changes with a complete, attributable audit record: partial and manual today → target 100%.
- Time to detect and repair drift on a delivered service: next manual audit today → target under 5 minutes, automatic.

Adoption

- Shadow-mode agreement between the agent's proposed change and what the engineer implemented: target 95%+ before the pilot starts.
- Share of eligible requests raised through the agent rather than by ticket: target 50% by the end of the pilot, 80%+ six months after expansion begins.
- Engineer confidence in the agent's reports, surveyed quarterly: target a clear majority rating it reliable by the end of the pilot, rising each quarter.
- Engineers and operators briefed before first use: target 100%.
- Requests declined or sent back for clarification: expected high at first and falling steadily; a rising trend is an early warning.
- Requests the agent could not complete that an engineer finished by hand: target a downward trend month on month.

## Data needs

- A current inventory of network equipment and tenants in one system of record.
- The numbering plans the agent is allowed to allocate from.
- Historical service tickets, to set the baselines above and test the agent against real wording.
- Access to an approved language model through the corporate gateway, with operator identity from single sign-on.

## Risks and mitigation

- The agent misunderstands a request. It shows its interpretation and waits for confirmation before acting, and rehearses every change first.
- A faulty change reaches the network. Changes are applied as one unit and reversed automatically if any part fails; the agent cannot reach devices directly.
- Trust erodes if it overstates success. It reports success only after verifying the service, and says plainly when something is still in progress or has failed.
- Dependence on the language model provider. Clear requests still work during a provider outage; ambiguous ones are declined with a clear message.
- Lab results may not transfer to production. Mitigated by the phased rollout below, with baselines measured before expansion.

## Adoption and change management plan

Phase 1, measure and prepare (weeks 1 to 4). Record the current baselines from the ticket system: cycle time, failed changes, incident rate and engineer hours. Confirm the equipment inventory and numbering plans are complete and owned. Agree the service types in scope for the pilot and the tenants that will take part. Name an executive sponsor, a network operations owner and a change manager for the initiative.

Phase 2, shadow mode (weeks 5 to 8). Run the agent alongside the existing process on one fabric segment. Operators submit real requests to the agent, but engineers still implement the change by the current method. Compare the agent's interpretation and proposed change with what the engineer did. Tune wording, inventory and guardrails until agreement is consistently high. No production change is made by the agent in this phase.

Phase 3, supervised pilot (weeks 9 to 16). The agent delivers changes for the pilot tenants, with the network team reviewing every outcome for the first weeks and then sampling. Existing change approval continues to apply; the agent's record of what was asked and verified becomes the evidence attached to each change. Track the success metrics weekly against the baselines. Exit criteria: lead time and failed-change targets met for the pilot scope, and no incident attributed to the agent.

Phase 4, expand (from month 5). Add service types and fabric segments one at a time, each with its own shadow period. Enable automatic drift repair per service type once the team is confident in the reports. Review the metrics monthly at the sponsor level.

People and roles. Network engineers move from executing changes to supervising, tuning and handling exceptions; this is a role change, not a headcount change, and it should be stated as such early. Operators who raise requests need a short briefing on how to phrase them and what a refusal means. The change manager owns the link between the agent's records and the change process.

Training and communication. A one-hour session for engineers on reading the agent's interpretation, confirming, and diagnosing a refusal or a failed change. A short guide for operators with example requests in the site's own vocabulary. A monthly note to stakeholders reporting the metrics and any incident.

Governance. Every change the agent makes carries the requesting operator's identity and is retained for audit. Scope changes, such as a new service type or automatic repair on a new class of service, require sign-off from the network operations owner and the change manager. A documented stop procedure returns provisioning to the manual process at any point without losing the services already delivered.
