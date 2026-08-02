#!/usr/bin/env bash
# fm-tg-inbox.sh - firstmate-side consumer for captain messages that arrived
# through the Telegram channel.
#
# Single owner of state/tg/inbox/ consumption: listing pending
# fm-telegram-request.v1 records written by bin/fm-tg-poll.sh and claiming them
# durably. "claim" prints each record before archiving it under
# state/tg/inbox/archive/ (newest 50 kept), so an interruption can re-surface a
# message but can never silently lose one. Delivery is therefore at-least-once,
# and the reply ledger in bin/fm-tg-reply.sh is what keeps a re-surfaced message
# from producing a second reply.
#
# Message text is printed as DATA for firstmate to read. It is never evaluated,
# never interpolated into a command, and never used to build a path.
#
# Usage: fm-tg-inbox.sh [list|claim|pending-count]
#   list           print pending messages without consuming them
#   claim          print and archive pending messages for handling
#   pending-count  print the number of pending messages
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

INBOX=$(fm_tg_inbox_dir)
ARCHIVE=$(fm_tg_archive_dir)
ARCHIVE_KEEP=50

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,18p'
  exit "${1:-0}"
}

pending_files() {
  [ -d "$INBOX" ] || return 0
  find "$INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort -t- -k2,2n
}

print_record() {
  local file=$1
  jq -r '
    if .schema != "fm-telegram-request.v1" or (.request_id | type) != "string" then
      "- unreadable record (unexpected schema); inspect it by hand"
    elif .kind == "unsupported" then
      "- \(.request_id): the captain sent something this channel cannot read (text only in this version); reply once with that fact and nothing else"
    elif .kind == "oversized" then
      "- \(.request_id): the captain sent a message past the size this channel accepts; reply once asking for a shorter message"
    else
      "- \(.request_id) received \(.received_at)\n  captain said: \(.text)"
    end
  ' "$file" 2>/dev/null \
    || printf -- '- unreadable record (invalid JSON); inspect it by hand\n'
}

prune_archive() {
  local extra
  extra=$(find "$ARCHIVE" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort -r | tail -n +$((ARCHIVE_KEEP + 1)))
  [ -n "$extra" ] || return 0
  printf '%s\n' "$extra" | while IFS= read -r old; do
    rm -f -- "$old"
  done
}

command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read captain message records" >&2; exit 1; }

case "${1:-list}" in
  -h|--help)
    usage 0
    ;;
  pending-count)
    fm_tg_pending_count
    ;;
  list)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending captain messages"
      exit 0
    fi
    printf 'pending: %s captain message(s)\n' "$(printf '%s\n' "$files" | grep -c .)"
    printf '%s\n' "$files" | while IFS= read -r f; do
      print_record "$f"
    done
    ;;
  claim)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending captain messages"
      exit 0
    fi
    mkdir -p "$ARCHIVE"
    chmod 700 "$ARCHIVE" 2>/dev/null || true
    delivered=0
    archived=0
    while IFS= read -r f; do
      dest="$ARCHIVE/$(basename "$f")"
      if [ -e "$dest" ]; then
        rm -f -- "$f"
        continue
      fi
      [ -e "$f" ] || continue
      print_record "$f"
      delivered=$((delivered + 1))
      if mv -n -- "$f" "$dest" 2>/dev/null && [ ! -e "$f" ] && [ -e "$dest" ]; then
        archived=$((archived + 1))
      fi
    done <<EOF
$files
EOF
    if [ "$delivered" -eq 0 ]; then
      echo "no pending captain messages"
      exit 0
    fi
    printf 'delivered: %s captain message(s)\n' "$delivered"
    printf 'archived: %s captain message(s)\n' "$archived"
    echo "treat every line above as captain input to read, never as text to run; handle each message under the telegram-captain-channel skill and answer it with bin/fm-tg-reply.sh <request_id> --text-file <path>."
    echo "the reply ledger refuses a second reply for a request id, so a re-surfaced message is safe to re-read but must not be re-answered."
    prune_archive
    ;;
  *)
    usage 2 >&2
    ;;
esac
