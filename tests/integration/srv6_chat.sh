#!/usr/bin/env bash
# US4 (T503/T504) — repo-root entry point for the SRv6 chat driver.
#
# The driver itself lives at agents/tests/integration/srv6_chat.sh next to
# its construct_chat.sh sibling; this wrapper makes the task path
# (tests/integration/srv6_chat.sh) work identically, so a receipt recorded
# through either path regenerates from both. All arguments
# (--request/--confirm/--decline/--help) and the environment (SUPERVISOR_URL,
# KUBECTL) pass through unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec bash "$REPO_ROOT/agents/tests/integration/srv6_chat.sh" "$@"
