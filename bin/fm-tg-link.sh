#!/usr/bin/env bash
# fm-tg-link.sh - bind a task to the Telegram message that asked for it.
#
# When the captain asks for real work from their phone, the answer cannot come
# back in that turn. This records the message's identity on the task itself, so a
# later session - after a restart, on a different day - can report the outcome to
# the same conversation without anyone having remembered anything.
#
# Usage:
#   fm-tg-link.sh <task-id> <request_id>   record the link
#   fm-tg-link.sh --check <task-id>        print "<request_id> <updates-sent>" when
#                                          an update is still due; silent otherwise
#   fm-tg-link.sh --clear <task-id>        drop the link
#
# --check is the gate for an unprompted update: it prints only while a link
# exists and its update budget (FM_TG_TASK_UPDATE_MAX, default 3) is not spent.
# A terminal outcome is never rationed - bin/fm-tg-reply.sh --task <id> --final
# always sends and then clears the link.
#
# Exit: 0 on success (--check prints nothing and still exits 0 when no update is
# due), 2 on a usage or validation error, 1 when the record could not be written.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

STATE=$(fm_tg_state_dir)

usage() { sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,19p'; exit "${1:-0}"; }
err() { printf 'fm-tg-link: %s\n' "$1" >&2; exit "${2:-2}"; }

meta_for() {
  local id=$1
  fm_pr_task_id_valid "$id" || err "invalid task id"
  printf '%s/%s.meta\n' "$STATE" "$id"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
  --check)
    [ "$#" -eq 2 ] || usage 2 >&2
    META=$(meta_for "$2")
    [ -f "$META" ] || exit 0
    RID=$(fm_tg_meta_get "$META" tg_request)
    fm_tg_base_request_id_valid "$RID" || exit 0
    SENT=$(fm_tg_meta_get "$META" tg_updates)
    case "$SENT" in ''|*[!0-9]*) SENT=0 ;; esac
    MAX=${FM_TG_TASK_UPDATE_MAX:-3}
    case "$MAX" in ''|*[!0-9]*) MAX=3 ;; esac
    [ "$MAX" -le "$FM_TG_TASK_UPDATE_LIMIT" ] || MAX=$FM_TG_TASK_UPDATE_LIMIT
    [ "$SENT" -lt "$MAX" ] || exit 0
    printf '%s %s\n' "$RID" "$SENT"
    ;;
  --clear)
    [ "$#" -eq 2 ] || usage 2 >&2
    META=$(meta_for "$2")
    fm_tg_meta_link_clear "$META" || err "the link could not be cleared" 1
    ;;
  '' | -*)
    usage 2 >&2
    ;;
  *)
    [ "$#" -eq 2 ] || usage 2 >&2
    META=$(meta_for "$1")
    [ -f "$META" ] || err "there is no such task to link" 1
    fm_tg_base_request_id_valid "$2" || err "invalid Telegram request id"
    EXISTING=$(fm_tg_meta_get "$META" tg_request)
    if ! fm_tg_base_request_id_valid "$EXISTING"; then
      fm_tg_send_capacity_available \
        || err "the Telegram reply ledger is full; finish or remove existing linked work before linking another task" 1
    fi
    fm_tg_meta_link_set "$META" "$2" "$(date +%s)" 0 \
      || err "the link could not be recorded" 1
    printf 'linked: %s -> %s\n' "$1" "$2"
    ;;
esac
