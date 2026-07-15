#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's per-task poll by
# writing state/<id>.check.sh (the watcher's check contract: output = wake
# firstmate, silence = keep sleeping).
#
# The armed poll reports two things about an open PR:
#   1. The PR merged - the long-standing signal that teardown can run.
#   2. A newly-seen UNRESOLVED finding from an automated reviewer, via
#      bin/fm-pr-bot-findings.sh. A review bot can post a substantive finding as
#      a review comment while its own CI check stays GREEN, so watching the
#      check rollup alone reads that PR as clean and misses the finding. Polling
#      for it makes the finding something firstmate is told about rather than
#      something it must remember to look for; see that script's header for the
#      detection and dedupe mechanics, and AGENTS.md section 7 "PR ready" for
#      the rule it enforces.
# A merged PR reports only the merge: teardown follows, so an open finding on it
# is no longer firstmate's next action.
#
# Findings dedupe through state/<id>.botfindings-seen, keyed on the review
# comment's URL, so each finding wakes firstmate once rather than every poll for
# the life of the PR. bin/fm-teardown.sh removes that marker with the task's
# other state.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
if [ "\$state" = "MERGED" ]; then
  echo "merged"
  exit 0
fi
"$FM_ROOT/bin/fm-pr-bot-findings.sh" "$URL" --seen-file "$STATE/$ID.botfindings-seen" 2>/dev/null || true
EOF
echo "armed: state/$ID.check.sh polls $URL for merge and unresolved bot findings"

# The poll's own contract is silence-unless-actionable, so it cannot report its
# own missing dependency: a findings poll that can never run would look exactly
# like a PR with no findings - the same "green means clean" failure this poll
# exists to end. jq is not part of the universal toolchain (bin/fm-bootstrap.sh
# requires it only for X mode, the non-tmux backends, and dispatch profiles), so
# say so LOUDLY here instead, at the one moment firstmate is deciding a PR is
# ready. The merge poll above needs no jq and still works.
for dep in gh jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "warning: $dep not found - the bot-finding poll cannot run, so read $URL's review-bot comments yourself before calling it clean (AGENTS.md section 7 'PR ready')" >&2
  fi
done
