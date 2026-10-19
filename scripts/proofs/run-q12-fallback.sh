#!/usr/bin/env bash
# Proof q12-fallback (US6, T546; SC-012): the UI's OFFLINE fallback list is
# the served list. When GET /suggested-prompts is unreachable the chat page
# falls back to a built-in list (ui/src/App.tsx); the guard suites pin both
# sides — the fallback matches the served file, every prompt (served and
# fallback) classifies as a provisioning request, the SRv6 examples stay
# inside the profile's proven verdicts, and each resolves to attachments
# with a registered probe host.
#
# This is the quickstart's command (specs/004-srv6-service-requests/
# quickstart.md Q12) run through a runner so the recorded argv stays a
# single replayable line: cd agents && . .venv/bin/activate && pytest <the
# two suites>. Read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT/agents"
# shellcheck disable=SC1091
. .venv/bin/activate
exec pytest tests/unit/test_suggested_prompts_ports_constructs.py \
            tests/unit/test_suggested_prompts_runnable.py "$@"
