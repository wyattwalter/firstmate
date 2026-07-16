#!/usr/bin/env bash
# Behavior tests for fm-board.sh: the board-column override set/clear helper.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=firstmate:fm-task" \
    "worktree=$home/projects/task" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf '%s\n' "$home"
}

test_set_writes_board_line() {
  local home
  home=$(make_home set)
  FM_HOME="$home" "$BOARD" task hold >/dev/null || fail "set should succeed"
  assert_grep "board=hold" "$home/state/task.meta" "meta should carry board=hold"
  pass "set writes the board= line"
}

test_set_is_idempotent_and_replaces() {
  local home count
  home=$(make_home idem)
  FM_HOME="$home" "$BOARD" task hold >/dev/null
  FM_HOME="$home" "$BOARD" task hold >/dev/null
  FM_HOME="$home" "$BOARD" task review >/dev/null
  count=$(grep -c '^board=' "$home/state/task.meta")
  [ "$count" -eq 1 ] || fail "exactly one board= line should remain, got $count"
  assert_grep "board=review" "$home/state/task.meta" "latest value should win"
  assert_no_grep "board=hold" "$home/state/task.meta" "old value should be gone"
  pass "setting is idempotent and replaces the prior value"
}

test_set_preserves_other_meta() {
  local home
  home=$(make_home preserve)
  FM_HOME="$home" "$BOARD" task progress >/dev/null
  assert_grep "window=firstmate:fm-task" "$home/state/task.meta" "unrelated meta must survive"
  assert_grep "kind=ship" "$home/state/task.meta" "unrelated meta must survive"
  pass "set preserves unrelated meta lines"
}

test_clear_removes_board_line() {
  local home
  home=$(make_home clear)
  FM_HOME="$home" "$BOARD" task push >/dev/null
  FM_HOME="$home" "$BOARD" task --clear >/dev/null || fail "clear should succeed"
  assert_no_grep "board=" "$home/state/task.meta" "board= line should be gone"
  assert_grep "kind=ship" "$home/state/task.meta" "unrelated meta must survive clear"
  pass "clear removes the board= line"
}

test_clear_absent_is_noop_success() {
  local home rc=0
  home=$(make_home clear-absent)
  FM_HOME="$home" "$BOARD" task --clear >/dev/null || rc=$?
  expect_code 0 "$rc" "clearing an absent override"
  assert_no_grep "board=" "$home/state/task.meta" "no board= line should appear"
  pass "clearing an absent override is a no-op success"
}

test_invalid_column_rejected() {
  local home rc=0
  home=$(make_home invalid)
  FM_HOME="$home" "$BOARD" task bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "invalid column should exit 2"
  assert_no_grep "board=" "$home/state/task.meta" "invalid value must not be written"
  pass "an invalid column is rejected without writing meta"
}

test_missing_meta_errors() {
  local home rc=0
  home=$(make_home missing)
  FM_HOME="$home" "$BOARD" nonexistent hold >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "missing meta should exit 1"
  pass "a missing meta file errors clearly"
}

test_all_valid_columns_accepted() {
  local home col
  home=$(make_home valid-cols)
  for col in decision progress push review hold; do
    FM_HOME="$home" "$BOARD" task "$col" >/dev/null || fail "column $col should be accepted"
    assert_grep "board=$col" "$home/state/task.meta" "board=$col should be written"
  done
  pass "all five valid columns are accepted"
}

test_set_writes_board_line
test_set_is_idempotent_and_replaces
test_set_preserves_other_meta
test_clear_removes_board_line
test_clear_absent_is_noop_success
test_invalid_column_rejected
test_missing_meta_errors
test_all_valid_columns_accepted
