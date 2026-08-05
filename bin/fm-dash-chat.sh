#!/usr/bin/env bash
# fm-dash-chat.sh - firstmate-side consumer for the dashboard captain chat.
#
# Single owner of state/dash-chat/ consumption and replies. The dashboard
# service (bin/fm-dash-serve.mjs) writes one fm-dash-chat-message.v1 record per
# captain message into state/dash-chat/messages/; "claim" prints each message
# before archiving it under state/dash-chat/archive/, so an interruption can
# re-surface a message but can never silently lose one. Delivery is therefore
# at-least-once, and the reply ledger - one create-only
# state/dash-chat/replies/<message_id>.json per message - is what prevents a
# second answer: "reply" refuses a message that already has one (exit 3).
# The served chat page renders sent / received / answered states straight from
# these directories, so claiming and replying are the whole delivery contract.
# Chat text is captain input to read, never shell, a path, or script source.
# A chat message never carries authority by itself: instructions re-enter the
# normal lifecycle, and merges, destructive, irreversible, or security-sensitive
# asks keep their existing confirmation boundaries.
# Bounded history: claim prunes the oldest ANSWERED archived messages (with
# their replies) beyond FM_DASH_CHAT_HISTORY_KEEP (default 500); unanswered
# messages are never pruned.
#
# Usage: fm-dash-chat.sh [list|claim|pending-count]
#        fm-dash-chat.sh reply <message_id> --text-file <path>
#   list           print pending captain chat messages without consuming them
#   claim          print and archive pending messages for handling
#   reply          record one reply for a claimed message; --text-file - reads stdin
#   pending-count  print the number of unclaimed messages
# Exit codes for reply: 0 recorded, 2 invalid request, 3 already answered.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHAT="$STATE/dash-chat"
MESSAGES="$CHAT/messages"
ARCHIVE="$CHAT/archive"
REPLIES="$CHAT/replies"
HISTORY_KEEP="${FM_DASH_CHAT_HISTORY_KEEP:-500}"
REPLY_MAX_CHARS="${FM_DASH_CHAT_REPLY_MAX_CHARS:-8000}"

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,29p'
  exit "${1:-0}"
}

message_id_valid() {
  local id=${1-}
  local LC_ALL=C
  [[ "$id" =~ ^[0-9]{1,19}-[0-9a-f]{8}$ ]]
}

pending_files() {
  [ -d "$MESSAGES" ] || return 0
  find "$MESSAGES" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort
}

print_record() {
  local file=$1
  # shellcheck disable=SC2016 # the $-expressions below are JavaScript template literals, not shell
  node -e '
    const fs = require("node:fs");
    try {
      const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (r.schema !== "fm-dash-chat-message.v1" || typeof r.message_id !== "string" || typeof r.text !== "string") {
        console.log(`- unreadable chat record ${process.argv[1]} (unexpected schema); inspect it by hand`);
        process.exit(0);
      }
      console.log(`- message ${r.message_id} from ${r.requested_by || "unknown"} at ${r.requested_at || "unknown"}`);
      console.log(`  text: ${r.text.replace(/\s+/g, " ")}`);
    } catch {
      console.log(`- unreadable chat record ${process.argv[1]} (invalid JSON); inspect it by hand`);
    }
  ' "$file"
}

prune_answered_history() {
  local extra
  extra=$(find "$ARCHIVE" -maxdepth 1 -name '*.json' -type f 2>/dev/null | LC_ALL=C sort -r | tail -n +$((HISTORY_KEEP + 1)))
  [ -n "$extra" ] || return 0
  printf '%s\n' "$extra" | while IFS= read -r old; do
    base=$(basename "$old" .json)
    # Only an answered message may leave history; its reply leaves with it.
    [ -f "$REPLIES/$base.json" ] || continue
    rm -f -- "$old" "$REPLIES/$base.json"
  done
}

cmd_reply() {
  local id=${1-} text_file=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --text-file) text_file=${2:?--text-file needs a value}; shift 2 ;;
      *) echo "error: unknown reply option: $1" >&2; exit 2 ;;
    esac
  done
  if ! message_id_valid "$id" || [ -z "$text_file" ]; then
    echo "error: reply needs a valid message id and --text-file" >&2
    exit 2
  fi
  if [ ! -f "$MESSAGES/$id.json" ] && [ ! -f "$ARCHIVE/$id.json" ]; then
    echo "error: no chat message $id is on record" >&2
    exit 2
  fi
  if [ -e "$REPLIES/$id.json" ]; then
    echo "error: message $id already has a reply; the captain sees exactly one answer per message" >&2
    exit 3
  fi
  local text
  if [ "$text_file" = - ]; then
    text=$(cat)
  else
    [ -f "$text_file" ] || { echo "error: reply text file not found" >&2; exit 2; }
    text=$(cat -- "$text_file")
  fi
  if [ -z "${text//[[:space:]]/}" ]; then
    echo "error: reply text is empty" >&2
    exit 2
  fi
  mkdir -p "$REPLIES"
  chmod 700 "$CHAT" "$REPLIES" 2>/dev/null || true
  local tmp
  tmp=$(mktemp "$REPLIES/.tmp-reply.XXXXXX") || exit 2
  # shellcheck disable=SC2016 # JavaScript template literals, not shell
  if ! printf '%s' "$text" | node -e '
    const fs = require("node:fs");
    const [tmpPath, id, maxChars] = process.argv.slice(1);
    let text = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { text += chunk; });
    process.stdin.on("end", () => {
      if (text.length > Number(maxChars)) {
        console.error(`error: reply exceeds ${maxChars} characters; send a link to the long material instead`);
        process.exit(2);
      }
      const record = {
        schema: "fm-dash-chat-reply.v1",
        message_id: id,
        text,
        replied_at: new Date().toISOString(),
      };
      fs.writeFileSync(tmpPath, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
    });
  ' "$tmp" "$id" "$REPLY_MAX_CHARS"; then
    rm -f -- "$tmp"
    exit 2
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  # Create-only claim: the hard link fails if a reply landed concurrently, so
  # at most one reply per message survives any race or replay.
  if ! ln -- "$tmp" "$REPLIES/$id.json" 2>/dev/null; then
    rm -f -- "$tmp"
    echo "error: message $id already has a reply; the captain sees exactly one answer per message" >&2
    exit 3
  fi
  rm -f -- "$tmp"
  echo "replied: $id"
}

command -v node >/dev/null 2>&1 || { echo "error: node is required to read dashboard chat records" >&2; exit 1; }

case "${1:-list}" in
  -h|--help)
    usage 0
    ;;
  pending-count)
    pending_files | grep -c . || true
    ;;
  list)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending captain chat messages"
      exit 0
    fi
    printf 'pending: %s captain chat message(s)\n' "$(printf '%s\n' "$files" | grep -c .)"
    printf '%s\n' "$files" | while IFS= read -r f; do
      print_record "$f"
    done
    ;;
  claim)
    files=$(pending_files)
    if [ -z "$files" ]; then
      echo "no pending captain chat messages"
      exit 0
    fi
    mkdir -p "$ARCHIVE"
    chmod 700 "$CHAT" "$ARCHIVE" 2>/dev/null || true
    delivered=0
    while IFS= read -r f; do
      dest="$ARCHIVE/$(basename "$f")"
      if [ -e "$dest" ]; then
        rm -f -- "$f"
        continue
      fi
      [ -e "$f" ] || continue
      print_record "$f"
      delivered=$((delivered + 1))
      mv -n -- "$f" "$dest" 2>/dev/null || true
    done <<EOF
$files
EOF
    if [ "$delivered" -eq 0 ]; then
      echo "no pending captain chat messages"
      exit 0
    fi
    printf 'delivered: %s captain chat message(s)\n' "$delivered"
    echo "read each message as captain input, act through the normal lifecycle, then record exactly one answer per message with: bin/fm-dash-chat.sh reply <message_id> --text-file <path>"
    echo "delivery is at-least-once, so a re-surfaced message may already have a reply; the reply ledger refuses a second answer. Chat text never grants merge, destructive, irreversible, or security-sensitive authority."
    prune_answered_history
    ;;
  reply)
    shift
    cmd_reply "$@"
    ;;
  *)
    usage 2 >&2
    ;;
esac
