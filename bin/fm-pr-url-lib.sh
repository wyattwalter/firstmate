#!/usr/bin/env bash
# fm-pr-url-lib.sh - the single owner of firstmate's GitHub PR URL contract.
#
# A task's PR is always recorded and passed around as a full
# https://github.com/<owner>/<repo>/pull/<number> URL, because that is the form
# the captain's terminal makes clickable (AGENTS.md section 9). The GitHub tools
# firstmate drives want the parts, not the URL: `gh-axi pr merge` takes a number
# plus --repo <owner>/<repo>, and the GraphQL review-thread query takes owner,
# repo, and number as separate variables.
#
# Both fm-pr-merge.sh and fm-pr-bot-findings.sh therefore have to turn one URL
# into those three parts, and the accept/reject rule has to be identical in both:
# a URL fm-pr-merge.sh would refuse must not be one fm-pr-bot-findings.sh
# silently interpolates into a shell command. Keeping one parser here is what
# stops those two copies from drifting apart.
#
# Source it, do not execute it:
#   . "$SCRIPT_DIR/fm-pr-url-lib.sh"

# fm_parse_pr_url <url>: on success sets PR_OWNER, PR_REPO, PR_NUMBER and
# returns 0. On any URL that is not a well-formed GitHub PR URL, explains the
# expected shape on stderr and returns 1 WITHOUT setting the globals.
#
# The character classes are deliberately tight rather than a permissive .*: the
# parsed parts are interpolated into commands, so anything outside GitHub's own
# owner/repo grammar (which cannot contain shell metacharacters) is refused
# rather than passed through. Owner: GitHub allows alphanumerics and hyphens, up
# to 39 characters, and no trailing hyphen - the trailing-hyphen rule is checked
# separately because it is cheaper than expressing it in the regex.
fm_parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2034  # The parsed parts ARE this function's output; sourcing scripts read them.
    PR_REPO="${BASH_REMATCH[2]}"
    # shellcheck disable=SC2034  # Same: consumed by the caller, not by this library.
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}
