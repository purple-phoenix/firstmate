#!/usr/bin/env bash
# fm-tg-reply.sh - send one captain-facing message through the Telegram channel.
#
# The single owner of outbound Telegram traffic. Nothing else in firstmate sends
# to Telegram, so every guarantee below holds for the whole channel.
#
# Usage:
#   fm-tg-reply.sh <request_id> --text-file <path>    answer one inbound message
#   fm-tg-reply.sh <request_id> -                     the same, reply on stdin
#   fm-tg-reply.sh --event <slug> --text-file <path>  push a captain-facing event
#   fm-tg-reply.sh --task <task-id> --text-file <path>  update the conversation
#                                                     that asked for that work
#   fm-tg-reply.sh --status <request_id|event-slug>   print this key's ledger state
#
# Options:
#   --text-file <path>   the composed message; required (or "-" for stdin)
#   --event <slug>       address an outbound notification instead of a reply
#   --task <task-id>     address the Telegram message that started this work,
#                        resolved through the link bin/fm-tg-link.sh recorded
#   --final              with --task, send the terminal outcome and clear the link
#   --resend             retry a delivery this client recorded as ambiguous
#   --dry-run            record the would-be message and send nothing
#
# AT MOST ONE REPLY PER KEY. Every send claims state/tg/sent/<key>.json before
# any network call, so a replayed inbound message, a retried firstmate turn, and
# a crashed-then-resumed session cannot produce a duplicate message. A key whose
# ledger says "sent" is refused (exit 3) rather than sent again.
#
# NEVER GUESSES ABOUT DELIVERY. A definite failure (Telegram refused the request,
# or the connection never established) clears the claim so the message can be
# retried. An AMBIGUOUS outcome - a timeout or a server-side error after the
# request went out - is recorded as ambiguous and refused (exit 4) until a human
# decides, because Telegram may or may not have delivered it. There is no
# fallback to another channel: this client either delivers here or reports.
#
# PLAIN TEXT ONLY. No parse_mode is ever sent, so Telegram renders the message
# literally: there is no markup entity a chunk boundary could tear in half and no
# escaping hazard from message content. Long messages are split on paragraph,
# line, and word boundaries within Telegram's per-message limit.
#
# Exit codes:
#   0 delivered (or recorded, under --dry-run)
#   2 usage, configuration, or composition error
#   3 this key was already answered; nothing was sent
#   4 delivery is ambiguous; nothing further was sent, decide by hand
#   5 delivery definitely failed; the key is free to retry
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

usage() {
  sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,50p'
  exit "${1:-0}"
}

err() { printf 'fm-tg-reply: %s\n' "$1" >&2; }

KEY=
TEXT_FILE=
RESEND=0
STATUS_KEY=
TASK_ID=
TASK_RID=
TASK_SENT=0
FINAL=0
DRY=${FM_TG_DRY_RUN:-}
case "$(printf '%s' "$DRY" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false|no|off) DRY=0 ;;
  *) DRY=1 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --event) KEY="event-${2:?--event needs a slug}"; shift 2 ;;
    --task) TASK_ID=${2:?--task needs a task id}; shift 2 ;;
    --final) FINAL=1; shift ;;
    --text-file) TEXT_FILE=${2:?--text-file needs a path}; shift 2 ;;
    --status) STATUS_KEY=${2:?--status needs a key}; shift 2 ;;
    --resend) RESEND=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -) TEXT_FILE=-; shift ;;
    -*) err "unknown option: $1"; usage 2 >&2 ;;
    *)
      if [ -n "$KEY" ]; then err "unexpected argument: $1"; usage 2 >&2; fi
      KEY=$1; shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { err "jq is required"; exit 2; }

SENT_DIR=$(fm_tg_sent_dir)

if [ -n "$STATUS_KEY" ]; then
  fm_tg_request_id_valid "$STATUS_KEY" || { err "invalid key"; exit 2; }
  if fm_tg_private_file_valid "$SENT_DIR/$STATUS_KEY.json" 600; then
    jq -r '"\(.key): \(.status) (\(.chunks_sent // 0) message(s) sent at \(.updated_at))"' \
      "$SENT_DIR/$STATUS_KEY.json" 2>/dev/null || echo "$STATUS_KEY: unreadable ledger record"
  else
    echo "$STATUS_KEY: no reply recorded"
  fi
  exit 0
fi

# --task resolves the key from the durable link instead of the caller's memory,
# and derives a distinct ledger key per update so a retry is refused as a
# duplicate while a genuinely new milestone is not.
if [ -n "$TASK_ID" ]; then
  [ -z "$KEY" ] || { err "use --task or a request id, not both"; exit 2; }
  LINK=$("$SCRIPT_DIR/fm-tg-link.sh" --check "$TASK_ID") || { err "the task link could not be read"; exit 2; }
  if [ -z "$LINK" ] && [ "$FINAL" = 1 ]; then
    # A terminal outcome is never rationed: read the link directly, past its
    # update budget, so the conversation always learns how the work ended.
    LINK_META="${FM_STATE_OVERRIDE:-$FM_HOME/state}/$TASK_ID.meta"
    LINK_RID=$(fm_tg_meta_get "$LINK_META" tg_request)
    LINK_SENT=$(fm_tg_meta_get "$LINK_META" tg_updates)
    case "$LINK_SENT" in ''|*[!0-9]*) LINK_SENT=0 ;; esac
    fm_tg_base_request_id_valid "$LINK_RID" && LINK="$LINK_RID $LINK_SENT"
  fi
  if [ -z "$LINK" ]; then
    err "$TASK_ID has no Telegram conversation waiting on it, or its update budget is spent; nothing was sent"
    exit 3
  fi
  TASK_RID=${LINK%% *}
  TASK_SENT=${LINK##* }
  [ "$TASK_SENT" -le "$FM_TG_TASK_UPDATE_LIMIT" ] \
    || { err "the task link has an invalid update count; nothing was sent"; exit 2; }
  KEY="$TASK_RID.u$((TASK_SENT + 1))"
fi

fm_tg_request_id_valid "$KEY" || { err "a valid request id, --task, or --event slug is required"; usage 2 >&2; }
[ -n "$TEXT_FILE" ] || { err "--text-file <path> (or -) is required"; usage 2 >&2; }

fm_tg_config_load
[ "$FM_TG_CONFIGURED" = 1 ] || { err "the Telegram channel is not configured; run bin/fm-tg-setup.sh status"; exit 2; }
[ "$FM_TG_ENABLED" = 1 ] || { err "the Telegram channel is not enabled; run bin/fm-tg-setup.sh status"; exit 2; }

LIMIT=${FM_TG_REPLY_MAX_CHARS:-3500}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=3500 ;; esac
[ "$LIMIT" -ge 200 ] 2>/dev/null && [ "$LIMIT" -le 4096 ] 2>/dev/null || LIMIT=3500
CAP=${FM_TG_REPLY_MAX_CHUNKS:-6}
case "$CAP" in ''|*[!0-9]*) CAP=6 ;; esac
[ "$CAP" -ge 1 ] 2>/dev/null && [ "$CAP" -le 20 ] 2>/dev/null || CAP=6

if [ "$TEXT_FILE" = - ]; then
  CHUNKS=$(fm_tg_split_message "$LIMIT" "$CAP") || { err "the message could not be split"; exit 2; }
else
  [ -f "$TEXT_FILE" ] || { err "message file not found"; exit 2; }
  CHUNKS=$(fm_tg_split_message "$LIMIT" "$CAP" < "$TEXT_FILE") || { err "the message could not be split"; exit 2; }
fi
N=$(printf '%s' "$CHUNKS" | jq 'length' 2>/dev/null) || N=0
case "$N" in ''|*[!0-9]*) N=0 ;; esac
[ "$N" -gt 0 ] || { err "the message is empty"; exit 2; }

NOW=$(date +%s)

if [ ! -e "$SENT_DIR/$KEY.json" ] && [ ! -L "$SENT_DIR/$KEY.json" ]; then
  if [ "$FINAL" != 1 ] || [ -z "$TASK_ID" ]; then
    fm_tg_send_capacity_available \
      || { err "the Telegram reply ledger is full; claim pending messages before sending more"; exit 2; }
  fi
fi

if [ "$DRY" = 1 ]; then
  fm_tg_outbox_prepare_slot \
    || { err "dry-run preview retention could not make room; nothing was recorded"; exit 2; }
fi

ledger_write() {  # <status> <chunks-sent>
  jq -cn --arg key "$KEY" --arg status "$1" --argjson chunks "$2" \
    --argjson total "$N" --argjson at "$NOW" \
    '{schema:"fm-telegram-sent.v1", key:$key, status:$status,
      chunks_sent:$chunks, chunks_total:$total, updated_at:$at}' \
    | fm_tg_private_publish_stdin "$SENT_DIR" "$KEY.json"
}

# Record that this update was delivered, so the next one gets a fresh key. A
# final outcome drops the link instead: the conversation is closed.
advance_task_link() {
  [ -n "$TASK_ID" ] || return 0
  if [ "$FINAL" = 1 ]; then
    "$SCRIPT_DIR/fm-tg-link.sh" --clear "$TASK_ID" >/dev/null 2>&1 || true
    return 0
  fi
  fm_tg_meta_link_set "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$TASK_ID.meta" \
    "$TASK_RID" "$(date +%s)" "$((TASK_SENT + 1))" >/dev/null 2>&1 || true
}

ledger_status() {
  fm_tg_private_file_valid "$SENT_DIR/$KEY.json" 600 || return 1
  jq -r '.status // ""' "$SENT_DIR/$KEY.json" 2>/dev/null
}

# Claim the key before any network call. A create-only claim is what makes the
# whole channel at-most-once: two concurrent senders cannot both win it.
jq -cn --arg key "$KEY" --argjson total "$N" --argjson at "$NOW" \
  '{schema:"fm-telegram-sent.v1", key:$key, status:"pending",
    chunks_sent:0, chunks_total:$total, updated_at:$at}' \
  | fm_tg_private_publish_stdin_once "$SENT_DIR" "$KEY.json"
CLAIM_RC=$?
if [ "$CLAIM_RC" != 0 ]; then
  if [ "$CLAIM_RC" = 2 ]; then
    err "the reply ledger could not be written; nothing was sent"
    exit 2
  fi
  prior=$(ledger_status) || prior=
  case "$prior" in
    sent)
      err "$KEY was already answered; refusing to send a second message"
      exit 3
      ;;
    ambiguous)
      if [ "$RESEND" != 1 ]; then
        err "$KEY has an ambiguous delivery: Telegram may or may not have it. Check the chat, then re-run with --resend to send it anyway."
        exit 4
      fi
      ;;
    pending|"")
      # A crashed send left the claim behind with nothing confirmed delivered.
      # Treat it exactly like an ambiguous outcome rather than assuming either way.
      if [ "$RESEND" != 1 ]; then
        err "$KEY has an interrupted send with no confirmed outcome. Check the chat, then re-run with --resend."
        exit 4
      fi
      ;;
    *)
      err "$KEY has an unreadable ledger record; inspect state/tg/sent/ by hand"
      exit 4
      ;;
  esac
fi

if [ "$DRY" = 1 ]; then
  if ! printf '%s' "$CHUNKS" | jq -c --arg key "$KEY" --argjson chat "$FM_TG_CHAT_ID" --argjson at "$NOW" \
    '{schema:"fm-telegram-outbox.v1", key:$key, chat_id:$chat, recorded_at:$at, texts:.}' \
    | fm_tg_private_publish_stdin "$(fm_tg_outbox_dir)" "$KEY.json"; then
    err "the dry-run record could not be written"
    exit 2
  fi
  ledger_write sent "$N" || { err "the reply ledger could not be updated"; exit 2; }
  advance_task_link
  printf 'DRY RUN: %s message(s) recorded for %s, nothing sent\n' "$N" "$KEY" >&2
  printf '%s\n' "$KEY"
  exit 0
fi

if ! fm_tg_token_load "$FM_TG_TOKEN_OWNER"; then
  ledger_write failed 0 >/dev/null 2>&1 || true
  rm -f -- "$SENT_DIR/$KEY.json" 2>/dev/null || true
  err "the stored bot token could not be read; nothing was sent"
  exit 5
fi

BODY_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-reply.XXXXXX") || { err "no temp file"; exit 2; }
PAYLOAD_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-reply-req.XXXXXX") || { rm -f -- "$BODY_FILE"; err "no temp file"; exit 2; }
trap 'rm -f -- "$BODY_FILE" "$PAYLOAD_FILE"' EXIT

SENT=0
i=0
while [ "$i" -lt "$N" ]; do
  # The chunk goes from jq straight into a JSON payload file. It is never an
  # argument, never inside a double-quoted shell string, and never a path.
  printf '%s' "$CHUNKS" | jq -c --argjson i "$i" --argjson chat "$FM_TG_CHAT_ID" \
    '{chat_id:$chat, text:.[$i], disable_web_page_preview:true}' > "$PAYLOAD_FILE" 2>/dev/null \
    || { err "the message payload could not be built"; ledger_write ambiguous "$SENT" >/dev/null 2>&1 || true; exit 2; }
  code=$(fm_tg_api sendMessage "$BODY_FILE" "$PAYLOAD_FILE")
  api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    case "$api_rc" in
      28)
        # The request went out and the answer never came back: Telegram may hold
        # it. Refuse to guess and refuse to resend automatically.
        ledger_write ambiguous "$SENT" >/dev/null 2>&1 || true
        err "delivery timed out after $SENT of $N message(s); outcome unknown"
        exit 4
        ;;
      5)
        rm -f -- "$SENT_DIR/$KEY.json" 2>/dev/null || true
        err "the Telegram API could not be reached; nothing was sent"
        exit 5
        ;;
      *)
        ledger_write ambiguous "$SENT" >/dev/null 2>&1 || true
        err "the connection dropped after $SENT of $N message(s); outcome unknown"
        exit 4
        ;;
    esac
  fi
  if [ "$code" != 200 ] || ! jq -e '.ok == true' "$BODY_FILE" >/dev/null 2>&1; then
    if [ "$SENT" -gt 0 ]; then
      ledger_write ambiguous "$SENT" >/dev/null 2>&1 || true
      err "Telegram refused message $((i + 1)) of $N after delivering $SENT; outcome unknown"
      exit 4
    fi
    case "$code" in
      5*)
        ledger_write ambiguous 0 >/dev/null 2>&1 || true
        err "Telegram returned a server error; outcome unknown"
        exit 4
        ;;
    esac
    rm -f -- "$SENT_DIR/$KEY.json" 2>/dev/null || true
    err "Telegram refused the message; nothing was sent"
    exit 5
  fi
  SENT=$((SENT + 1))
  i=$((i + 1))
done

ledger_write sent "$SENT" || { err "the message was delivered but the reply ledger could not be updated"; exit 2; }
advance_task_link
printf '%s\n' "$KEY"
exit 0
