#!/usr/bin/env bash
# fm-board.sh - set or clear a task's board-column override in state/<id>.meta.
#
# The self-hosted fleet dashboard categorizes each task into a board column by
# inferring from its status/note text and PR state, but honors an explicit
# top-level `board` field on a task as an override that wins over inference.
# bin/fm-fleet-snapshot.sh emits that field from a `board=<column>` line in the
# task's meta (only when the value is one of the valid keys below), so writing it
# here parks the task in the chosen column regardless of what its status says.
#
# Valid columns match the dashboard's keys exactly:
#   decision  progress  push  review  hold
#
# Usage:
#   fm-board.sh <id> <column>   # set the override (idempotent)
#   fm-board.sh <id> --clear    # remove the board= line (no-op if absent)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
usage: fm-board.sh <id> <column>   set board-column override (decision|progress|push|review|hold)
       fm-board.sh <id> --clear    remove the board-column override
EOF
}

[ $# -eq 2 ] || { usage >&2; exit 2; }
ID=$1
ACTION=$2

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "fm-board: no meta for task '$ID' ($META)" >&2; exit 1; }

# Drop every board= line, preserving the rest of the meta byte-for-byte.
strip_board() {
  local tmp
  tmp=$(mktemp "$META.XXXXXX")
  grep -v '^board=' "$META" > "$tmp" || true
  mv "$tmp" "$META"
}

case "$ACTION" in
  --clear)
    strip_board
    echo "cleared: board override on $ID"
    ;;
  decision|progress|push|review|hold)
    strip_board
    echo "board=$ACTION" >> "$META"
    echo "set: board=$ACTION on $ID"
    ;;
  *)
    echo "fm-board: invalid column '$ACTION' (want one of: decision progress push review hold, or --clear)" >&2
    exit 2
    ;;
esac
