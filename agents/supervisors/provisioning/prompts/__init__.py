"""System prompts for the provisioning supervisor (Phase 3).

The subject kept its prompts inline in ``graph.py``; this tier extracts
them into ``prompts/system.py`` so the classifier vocabulary (T086–T088)
and the nonce-fenced data-block wrappers (T094/T095, FR-028) are reviewable
on their own and can be mounted as the ``supervisor-prompts`` ConfigMap
(contracts/kubernetes-objects.md).
"""
