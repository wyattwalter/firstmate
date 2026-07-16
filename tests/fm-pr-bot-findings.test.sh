#!/usr/bin/env bash
# Tests for bin/fm-pr-bot-findings.sh and the poll bin/fm-pr-check.sh arms with
# it: the mechanism that stops a review bot's finding from being missed when the
# bot posts it as a review COMMENT while its own CI status check stays GREEN.
# Watching the check rollup alone reads such a PR as clean, which is exactly the
# failure this covers.
#
# The GraphQL responses are fixtures modeled on the real appsmithorg/appsmith
# #41996 finding that motivated the script (author login "hacktron-app",
# __typename "Bot", isResolved false) - notably a Bot login with NO "[bot]"
# suffix, so a suffix-only detector would miss it.
#
# Matrix:
#   (a) green check + unresolved bot finding -> exactly one wake line
#   (b) the same finding on a later poll is deduped -> silence
#   (c) a NEW finding after a deduped one still wakes
#   (d) resolved bot finding -> silence
#   (e) unresolved HUMAN comment -> silence (no false wake on ordinary review)
#   (f) no review threads at all -> silence
#   (g) a "<name>[bot]" login is detected too
#   (h) FM_BOT_REVIEWER_EXTRA promotes a plain-User reviewer to a bot
#   (i) a failed GraphQL read stays silent and exits non-zero
#   (j) a malformed PR URL is refused before any gh call
#   (k) the armed check.sh reports a merged PR as "merged" and skips findings
#   (l) the armed check.sh surfaces an unresolved finding on an OPEN, green PR
#   (m) arming without jq warns loudly instead of leaving the poll silently inert
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOT_FINDINGS="$ROOT/bin/fm-pr-bot-findings.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-bot-findings-tests)
PR_URL=https://github.com/example/repo/pull/7

# A review thread node as the GraphQL query shapes it.
# Args: resolved login typename body url
thread_node() {
  cat <<EOF
{"isResolved": $1, "comments": {"nodes": [
  {"author": {"login": "$2", "__typename": "$3"}, "body": "$4", "url": "$5"}
]}}
EOF
}

# Wrap thread nodes in the full GraphQL envelope. Args: case_dir node...
write_graphql_response() {
  local case_dir=$1 nodes
  shift
  nodes=$(printf '%s,' "$@")
  nodes=${nodes%,}
  cat > "$case_dir/graphql.json" <<EOF
{"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [$nodes]}}}}}
EOF
}

# gh mock: answers `gh api graphql` from the fixture and `gh pr view` from
# PR_STATE, so the PR's check rollup can be green while a finding is pending.
# Args: case_dir [pr_state]
add_gh_mock() {
  local case_dir=$1 pr_state=${2:-OPEN}
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case "\${1:-} \${2:-}" in
  "api graphql")
    if [ -n "\${FM_TEST_GRAPHQL_FAIL:-}" ]; then
      echo "error: could not resolve to a Repository" >&2
      exit 1
    fi
    cat "$case_dir/graphql.json"
    exit 0
    ;;
  "pr view")
    printf '%s\n' '$pr_state'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/state"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

run_findings() {
  local case_dir=$1; shift
  PATH="$case_dir/fakebin:$PATH" "$BOT_FINDINGS" "$@"
}

# The finding fixture: a Bot author whose login carries no [bot] suffix, leading
# with a severity-badge <img> exactly as the real bot's body does.
BOT_BODY='<img alt=\"MEDIUM\" src=\"https://app.example.ai/badges/Medium.svg\" align=\"top\"> **Broken Anti-Enumeration via Mono.empty() Propagation**'
BOT_URL="$PR_URL#discussion_r3582797540"

test_green_check_unresolved_bot_finding_wakes_once() {
  local case_dir out lines
  case_dir=$(make_case green-check-bot-finding)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"

  out=$(run_findings "$case_dir" "$PR_URL") || fail "green-check-bot-finding: script failed"

  lines=$(printf '%s' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "green-check-bot-finding: expected exactly one wake line, got $lines"$'\n'"$out"
  assert_contains "$out" "bot-finding: hacktron-app" \
    "green-check-bot-finding: the bot author was not reported"
  assert_contains "$out" "$BOT_URL" \
    "green-check-bot-finding: the finding's comment URL was not reported"
  assert_contains "$out" "Broken Anti-Enumeration" \
    "green-check-bot-finding: the finding summary was not reported"
  assert_not_contains "$out" "<img" \
    "green-check-bot-finding: raw HTML leaked into the wake line"
  pass "an unresolved bot finding on a green PR produces exactly one wake line"
}

test_seen_finding_is_deduped() {
  local case_dir first second
  case_dir=$(make_case dedupe)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"

  first=$(run_findings "$case_dir" "$PR_URL" --seen-file "$case_dir/seen") \
    || fail "dedupe: first poll failed"
  [ -n "$first" ] || fail "dedupe: first poll should surface the finding"

  second=$(run_findings "$case_dir" "$PR_URL" --seen-file "$case_dir/seen") \
    || fail "dedupe: second poll failed"
  [ -z "$second" ] || fail "dedupe: an already-surfaced finding woke firstmate again"$'\n'"$second"
  pass "a finding already surfaced is deduped on later polls"
}

test_new_finding_after_dedupe_still_wakes() {
  local case_dir out lines new_url
  case_dir=$(make_case new-after-dedupe)
  new_url="$PR_URL#discussion_r9999999999"
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"
  run_findings "$case_dir" "$PR_URL" --seen-file "$case_dir/seen" >/dev/null \
    || fail "new-after-dedupe: first poll failed"

  # The bot posts a second finding; the first is still unresolved.
  write_graphql_response "$case_dir" \
    "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")" \
    "$(thread_node false hacktron-app Bot 'A second, different finding' "$new_url")"

  out=$(run_findings "$case_dir" "$PR_URL" --seen-file "$case_dir/seen") \
    || fail "new-after-dedupe: second poll failed"

  lines=$(printf '%s' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "new-after-dedupe: expected only the NEW finding, got $lines lines"$'\n'"$out"
  assert_contains "$out" "$new_url" "new-after-dedupe: the new finding was not surfaced"
  assert_not_contains "$out" "$BOT_URL" "new-after-dedupe: the already-seen finding was re-surfaced"
  pass "a new finding still wakes firstmate after an earlier one was deduped"
}

test_resolved_bot_finding_is_silent() {
  local case_dir out
  case_dir=$(make_case resolved)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node true hacktron-app Bot "$BOT_BODY" "$BOT_URL")"

  out=$(run_findings "$case_dir" "$PR_URL") || fail "resolved: script failed"
  [ -z "$out" ] || fail "resolved: a resolved finding should not wake firstmate"$'\n'"$out"
  pass "a resolved bot finding stays silent"
}

test_human_comment_is_silent() {
  local case_dir out
  case_dir=$(make_case human)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" \
    "$(thread_node false williammartin User 'Could I interest you in the following tests' "$PR_URL#discussion_r1")"

  out=$(run_findings "$case_dir" "$PR_URL") || fail "human: script failed"
  [ -z "$out" ] || fail "human: an ordinary human review comment must not wake firstmate"$'\n'"$out"
  pass "an unresolved human review comment does not wake firstmate"
}

test_no_threads_is_silent() {
  local case_dir out
  case_dir=$(make_case no-threads)
  add_gh_mock "$case_dir" OPEN
  cat > "$case_dir/graphql.json" <<'EOF'
{"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": []}}}}}
EOF

  out=$(run_findings "$case_dir" "$PR_URL") || fail "no-threads: script failed"
  [ -z "$out" ] || fail "no-threads: a PR with no review threads must stay silent"$'\n'"$out"
  pass "a PR with no review threads stays silent"
}

test_bracket_bot_login_detected() {
  local case_dir out
  case_dir=$(make_case bracket-bot)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" \
    "$(thread_node false 'some-reviewer[bot]' User 'A finding from a [bot]-suffixed login' "$BOT_URL")"

  out=$(run_findings "$case_dir" "$PR_URL") || fail "bracket-bot: script failed"
  assert_contains "$out" "bot-finding: some-reviewer[bot]" \
    "bracket-bot: a [bot]-suffixed login was not detected as an automated reviewer"
  pass "a <name>[bot] login is detected as an automated reviewer"
}

test_extra_reviewer_regex_detected() {
  local case_dir out
  case_dir=$(make_case extra-regex)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" \
    "$(thread_node false securitybot User 'A finding from a PAT-driven reviewer' "$BOT_URL")"

  out=$(run_findings "$case_dir" "$PR_URL") || fail "extra-regex: script failed"
  [ -z "$out" ] || fail "extra-regex: a plain User should not be a bot without the override"$'\n'"$out"

  out=$(FM_BOT_REVIEWER_EXTRA='^securitybot$' run_findings "$case_dir" "$PR_URL") \
    || fail "extra-regex: script failed with override"
  assert_contains "$out" "bot-finding: securitybot" \
    "extra-regex: FM_BOT_REVIEWER_EXTRA did not promote the reviewer to a bot"
  pass "FM_BOT_REVIEWER_EXTRA promotes a plain-User reviewer to an automated reviewer"
}

test_query_failure_is_silent_and_nonzero() {
  local case_dir out rc
  case_dir=$(make_case query-failure)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"

  set +e
  out=$(FM_TEST_GRAPHQL_FAIL=1 run_findings "$case_dir" "$PR_URL" 2>/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "query-failure: an unreadable PR should exit non-zero"
  [ -z "$out" ] || fail "query-failure: a failed read must not print a wake line"$'\n'"$out"
  pass "a failed review-thread read stays silent and exits non-zero"
}

test_malformed_url_refused_before_gh() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  add_gh_mock "$case_dir" OPEN

  set +e
  run_findings "$case_dir" 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: a non-GitHub PR URL should be refused"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  [ ! -s "$case_dir/gh.log" ] || fail "malformed-url: gh was called for a malformed URL"
  pass "a malformed PR URL is refused before any gh call"
}

# --- the armed poll (bin/fm-pr-check.sh) ------------------------------------

arm_check() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-b1 "$PR_URL" >/dev/null
}

run_armed_check() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-b1.check.sh"
}

test_armed_check_reports_merge_and_skips_findings() {
  local case_dir out
  case_dir=$(make_case armed-merged)
  add_gh_mock "$case_dir" MERGED
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"
  arm_check "$case_dir"

  out=$(run_armed_check "$case_dir")
  [ "$out" = "merged" ] || fail "armed-merged: a merged PR should report only 'merged', got: $out"
  pass "the armed poll reports a merged PR as merged without also reporting findings"
}

test_armed_check_surfaces_finding_on_open_green_pr() {
  local case_dir out lines
  case_dir=$(make_case armed-open-finding)
  add_gh_mock "$case_dir" OPEN
  write_graphql_response "$case_dir" "$(thread_node false hacktron-app Bot "$BOT_BODY" "$BOT_URL")"
  arm_check "$case_dir"

  out=$(run_armed_check "$case_dir")
  lines=$(printf '%s' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "armed-open-finding: expected exactly one wake line, got $lines"$'\n'"$out"
  assert_contains "$out" "bot-finding: hacktron-app" \
    "armed-open-finding: the armed poll did not surface the unresolved bot finding"
  assert_not_contains "$out" "merged" "armed-open-finding: an open PR was reported merged"

  # The watcher polls every CHECK_INTERVAL for the life of the PR, so a second
  # poll must be silent or the finding would wake firstmate over and over.
  out=$(run_armed_check "$case_dir")
  [ -z "$out" ] || fail "armed-open-finding: the armed poll re-surfaced a seen finding"$'\n'"$out"
  assert_present "$case_dir/state/task-b1.botfindings-seen" \
    "armed-open-finding: the dedupe marker was not written to the task's state"
  pass "the armed poll surfaces an unresolved finding on an open green PR exactly once"
}

test_green_check_unresolved_bot_finding_wakes_once
test_seen_finding_is_deduped
test_new_finding_after_dedupe_still_wakes
test_resolved_bot_finding_is_silent
test_human_comment_is_silent
test_no_threads_is_silent
test_bracket_bot_login_detected
test_extra_reviewer_regex_detected
test_query_failure_is_silent_and_nonzero
test_malformed_url_refused_before_gh
test_armed_check_reports_merge_and_skips_findings
test_armed_check_surfaces_finding_on_open_green_pr

# A findings poll that cannot run must not look like a PR with no findings, so
# fm-pr-check.sh warns at arm time - the one moment firstmate is deciding a PR
# is ready - rather than leaving the poll silently inert.
test_arm_warns_when_jq_missing() {
  local case_dir stderr
  case_dir=$(make_case arm-no-jq)
  add_gh_mock "$case_dir" OPEN
  # A PATH with the real tools fm-pr-check needs but NO jq. PATH cannot subtract
  # one binary from a directory that also holds grep and cut, so link in exactly
  # what the script uses and leave jq out.
  mkdir -p "$case_dir/nojq"
  for tool in bash env dirname grep cut tail cat; do
    ln -sf "$(command -v "$tool")" "$case_dir/nojq/$tool"
  done
  ln -sf "$case_dir/fakebin/gh" "$case_dir/nojq/gh"
  command -v jq >/dev/null 2>&1 || fail "arm-no-jq: fixture assumes jq exists on PATH to be excluded"

  stderr=$(FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/nojq" "$PR_CHECK" task-b1 "$PR_URL" 2>&1 >/dev/null) \
    || fail "arm-no-jq: fm-pr-check should still arm the merge poll"

  assert_contains "$stderr" "jq not found" \
    "arm-no-jq: a missing jq left the findings poll silently inert"
  assert_contains "$stderr" "review-bot comments yourself" \
    "arm-no-jq: the warning did not say what to do instead"
  assert_present "$case_dir/state/task-b1.check.sh" \
    "arm-no-jq: the merge poll should still be armed without jq"
  pass "fm-pr-check warns loudly when the findings poll cannot run"
}

test_arm_warns_when_jq_missing
