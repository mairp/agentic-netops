#!/usr/bin/env bash
# bootstrap-srlinux-repo.sh — create and populate the public SR Linux repository.
#
# Creates github.com/mairp/agentic-netops-srlinux (public, Apache-2.0), adds it
# to THIS clone as the remote `srlinux`, pushes the current branch to `main`
# there, and sets the repository description and topics.
#
# It is idempotent: `gh repo view` decides whether to create, and every later
# step is a no-op when it is already in the required state. It never touches
# the `origin` remote — not its URL, not its refs — so running this in the
# authoring clone of mairp/agentic-netops cannot push anything upstream.
#
#   ./scripts/bootstrap-srlinux-repo.sh --dry-run   # print what would happen
#   ./scripts/bootstrap-srlinux-repo.sh
#
# Options:
#   --dry-run        print every command instead of running the mutating ones
#   --repo <o/n>     override the target repository (default mairp/agentic-netops-srlinux)
#   --remote <name>  override the local remote name (default srlinux)
#   --branch <name>  override the remote branch to push to (default main)
#   -h | --help      this text
set -euo pipefail

REPO="${SRLINUX_REPO:-mairp/agentic-netops-srlinux}"
REMOTE="${SRLINUX_REMOTE:-srlinux}"
TARGET_BRANCH="${SRLINUX_BRANCH:-main}"
DRY_RUN=false

DESCRIPTION="Autonomous intent-to-fabric operations on a Nokia SR Linux EVPN/VXLAN fabric: an AGNTCY multi-agent intent tier, Kubernetes controllers and a gNMI southbound. Apache-2.0."
TOPICS=(srlinux nokia evpn vxlan containerlab agentic-ai agntcy kubernetes gnmi)

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --repo)    REPO="${2:?--repo needs a value}"; shift 2 ;;
    --remote)  REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    --branch)  TARGET_BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '[bootstrap-srlinux-repo] %s\n' "$*"; }

# run: execute a mutating command, or print it under --dry-run.
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  DRY-RUN would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v gh  >/dev/null 2>&1 || { echo "missing gh (GitHub CLI)" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "missing git" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git work tree: $REPO_ROOT" >&2; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated: run 'gh auth login' first" >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] || { echo "detached HEAD: check out a branch first" >&2; exit 1; }
say "repo=$REPO remote=$REMOTE local-branch=$BRANCH -> remote-branch=$TARGET_BRANCH"
[[ "$DRY_RUN" == true ]] && say "DRY RUN: nothing will be created, pushed or changed"

# --- 1. the repository -------------------------------------------------------
# `gh repo create ... --source . --remote <name> --push` is the one-shot form;
# it fails outright when the repository already exists, so the existence check
# is what makes this script re-runnable. When the repository is absent we use
# the same flags, minus --push, and push explicitly below so the current branch
# lands on `main` whatever it is called locally.
if gh repo view "$REPO" >/dev/null 2>&1; then
  say "repository $REPO already exists — not creating it"
else
  say "creating $REPO (public)"
  run gh repo create "$REPO" \
      --public \
      --description "$DESCRIPTION" \
      --source . \
      --remote "$REMOTE"
fi

# --- 2. the local remote -----------------------------------------------------
# `origin` is never read, rewritten or pushed to here.
REMOTE_URL="https://github.com/${REPO}.git"
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  CURRENT_URL="$(git remote get-url "$REMOTE")"
  if [[ "$CURRENT_URL" == "$REMOTE_URL" || "$CURRENT_URL" == "git@github.com:${REPO}.git" ]]; then
    say "remote $REMOTE already points at $REPO"
  else
    say "remote $REMOTE points at $CURRENT_URL — repointing at $REMOTE_URL"
    run git remote set-url "$REMOTE" "$REMOTE_URL"
  fi
else
  say "adding remote $REMOTE -> $REMOTE_URL"
  run git remote add "$REMOTE" "$REMOTE_URL"
fi

if [[ "$(git remote get-url origin 2>/dev/null || true)" == "$REMOTE_URL" ]]; then
  echo "refusing to continue: 'origin' points at $REPO; this script must not push through origin" >&2
  exit 1
fi

# --- 3. push the current branch to <TARGET_BRANCH> ---------------------------
say "pushing $BRANCH -> $REMOTE/$TARGET_BRANCH"
run git push "$REMOTE" "HEAD:refs/heads/${TARGET_BRANCH}"

# --- 4. description, homepage and default branch -----------------------------
say "setting description and default branch"
run gh repo edit "$REPO" \
    --description "$DESCRIPTION" \
    --default-branch "$TARGET_BRANCH"

# --- 5. topics ---------------------------------------------------------------
# `gh repo edit --add-topic` is additive and idempotent: a topic that is
# already set is accepted and left alone.
say "setting topics: ${TOPICS[*]}"
TOPIC_ARGS=()
for t in "${TOPICS[@]}"; do TOPIC_ARGS+=(--add-topic "$t"); done
run gh repo edit "$REPO" "${TOPIC_ARGS[@]}"

say "done: https://github.com/${REPO} (branch ${TARGET_BRANCH})"
if [[ "$DRY_RUN" == true ]]; then
  say "DRY RUN: nothing above was executed"
fi
