#!/usr/bin/env bash
# fm-pr-bot-findings.sh - print a PR's UNRESOLVED automated-reviewer findings.
#
# Why this exists: a code-review bot can post a substantive finding as a PR
# review comment while its own CI status check stays GREEN. Firstmate and its
# crewmates watch the check rollup, so a green check reads as "no findings" and
# the comment-borne finding is missed. This has happened on real PRs twice. This
# script is the mechanical half of closing that gap (the instruction half lives
# in AGENTS.md section 7 "PR ready" and the crew brief): it makes an unresolved
# bot finding a thing firstmate is TOLD about rather than a thing it must
# remember to go look for.
#
# Usage:
#   fm-pr-bot-findings.sh <pr-url> [--seen-file <path>]
#   fm-pr-bot-findings.sh --help
#
# Output is the watcher's check contract (AGENTS.md section 7): one line per
# finding that firstmate should wake for, and NOTHING otherwise. Silence is the
# normal, healthy answer, so this is safe to run from state/<id>.check.sh.
# Each line:
#   bot-finding: <login> <comment-url> - <summary>
#
# Dedupe (--seen-file <path>): print only findings whose comment URL is not
# already listed in <path>, then append the ones printed. Without the flag,
# every current unresolved finding prints. The armed poll passes a seen-file so
# a given finding wakes firstmate ONCE instead of every poll for the life of the
# PR. The marker advances when the line is PRINTED, matching how the watcher's
# own .seen-* markers advance on surface (bin/fm-watch.sh); a wake dropped after
# printing is recovered by the heartbeat fleet review rather than by re-waking
# on every poll, which is the cheaper failure to have.
#
# Detecting "a bot" generically, not one vendor:
#   - author.__typename == "Bot" is the primary signal. GitHub types a comment
#     posted by a GitHub App's installation token as Bot, whatever the app is
#     called, so this needs no vendor list. Verified 2026-07-15 against the
#     appsmithorg/appsmith#41996 finding that motivated this script: its author
#     is login "hacktron-app", __typename "Bot".
#   - A "<name>[bot]" login is also honored, because that is how a Bot author
#     renders in the REST API and in a Bot login GitHub has already suffixed.
#     Note it is NOT sufficient alone: the real hacktron-app login above carries
#     no [bot] suffix, so a suffix-only check would have missed the exact case
#     this script exists for.
#   - FM_BOT_REVIEWER_EXTRA is an optional extended-regex of additional author
#     logins to treat as automated reviewers, for a reviewer that posts under a
#     plain user account (a bot driven by a personal access token is typed User,
#     not Bot). Example: FM_BOT_REVIEWER_EXTRA='^(securitybot|our-linter)$'
#
# Resolution state comes from GraphQL reviewThreads.isResolved: it is the only
# API that reports whether a review thread was resolved, which REST
# /pulls/<n>/comments does not expose. That is also why this uses `gh api
# graphql` directly rather than gh-axi: gh-axi's own `pr view --reviews` and its
# `api` digest output are shaped for an agent to read, not for a script to
# parse, and its `api graphql` does not forward a custom query. This mirrors the
# existing split in bin/ - gh-axi for agent-facing and mutating GitHub calls
# (fm-pr-merge.sh), raw `gh --json`/`--jq` for machine-parsed reads
# (fm-pr-check.sh, fm-teardown.sh).
#
# An outdated-but-unresolved thread still counts: the bot's finding stands until
# someone resolves it, and "the diff moved" is not the same as "it was handled".
#
# Exit status is 0 whenever the PR could be read, whether or not it had
# findings, so a caller cannot mistake "no findings" for "the query failed". Any
# failure to read the PR (network, auth, an unknown PR) exits non-zero and
# prints nothing, so the poll stays silent rather than waking firstmate for an
# infrastructure hiccup it cannot act on.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-url-lib.sh
. "$SCRIPT_DIR/fm-pr-url-lib.sh"

# Print this script's header block as its help text, stopping at the first
# non-comment line so the two cannot drift apart as the header grows.
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  --help|-h|'') usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
esac

URL=$1
shift
SEEN_FILE=

while [ $# -gt 0 ]; do
  case "$1" in
    --seen-file)
      SEEN_FILE=${2:?error: --seen-file needs a path}
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

fm_parse_pr_url "$URL" || exit 1

command -v gh >/dev/null 2>&1 || { echo "error: gh is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# One thread's first comment is the finding; later comments are the discussion.
# 100 threads is well past what a reviewed PR carries in practice, and a bot
# posting more than that is a different problem than this poll solves.
# shellcheck disable=SC2016  # $owner/$repo/$number are GraphQL variables bound by gh's -F flags; the shell must NOT expand them.
QUERY='
query($owner:String!,$repo:String!,$number:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      reviewThreads(first:100){
        nodes{
          isResolved
          comments(first:1){
            nodes{ author{ login __typename } body url }
          }
        }
      }
    }
  }
}'

raw=$(gh api graphql -f query="$QUERY" \
  -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" 2>/dev/null) || {
  echo "error: could not read review threads for $URL" >&2
  exit 1
}

# Select unresolved threads whose first comment came from an automated reviewer,
# then render one compact line each. The body is stripped of HTML (bots lead
# with severity-badge <img> tags), of markdown emphasis, and of newlines, then
# truncated: the wake reason wants enough to triage, not the whole finding.
findings=$(printf '%s' "$raw" | jq -r --arg extra "${FM_BOT_REVIEWER_EXTRA:-}" '
  [ .data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)
    | .comments.nodes[0]
    | select(. != null)
    | select(.author != null)
    | select(
        .author.__typename == "Bot"
        or (.author.login | test("\\[bot\\]$"))
        or (($extra | length) > 0 and (.author.login | test($extra)))
      )
  ]
  | .[]
  | . as $c
  | ($c.body // "")
    | gsub("<[^>]*>"; " ")
    | gsub("[*`#]"; "")
    | gsub("\\s+"; " ")
    | ltrimstr(" ")
    | .[0:100]
    | . as $summary
    | "bot-finding: \($c.author.login) \($c.url) - \($summary)"
' 2>/dev/null) || {
  echo "error: could not parse review threads for $URL" >&2
  exit 1
}

[ -n "$findings" ] || exit 0

if [ -z "$SEEN_FILE" ]; then
  printf '%s\n' "$findings"
  exit 0
fi

# Dedupe on the comment URL: it embeds the review comment's own id
# (#discussion_r<id>), so it is stable across polls and unique per finding, and
# it survives the bot editing the body afterwards.
[ -e "$SEEN_FILE" ] || : > "$SEEN_FILE"

fresh=
while IFS= read -r line; do
  [ -n "$line" ] || continue
  comment_url=$(printf '%s' "$line" | awk '{print $3}')
  if [ -n "$comment_url" ] && ! grep -qxF "$comment_url" "$SEEN_FILE"; then
    fresh="${fresh:+$fresh
}$line"
    printf '%s\n' "$comment_url" >> "$SEEN_FILE"
  fi
done <<EOF
$findings
EOF

[ -n "$fresh" ] || exit 0
printf '%s\n' "$fresh"
