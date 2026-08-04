#!/usr/bin/env bash
# One bounded Telegram long poll for new captain messages.
#
# INERT BY DEFAULT: a hard no-op (exit 0, no output) unless config/telegram.json
# exists, carries "enabled": true with a paired numeric identity, and a bot token
# resolves. Until the operator completes bin/fm-tg-setup.sh, nothing here runs.
#
# The watcher runs this through the registered state/fm-telegram.check.sh shim on
# the shared check cadence owned by bin/fm-cadence.sh, and its contract is the
# standard one: printing a line wakes firstmate, silence keeps it sleeping.
#
#   new captain message(s)   -> commit each as a durable inbox record, then print
#                               "tg-message <n> pending"
#   nothing new, nothing pending -> print nothing, exit 0
#   configuration/auth failure   -> print one rate-limited "tg-mode-error ..."
#
# INGRESS SAFETY - every inbound update must clear all of these before it becomes
# a request; anything else is dropped without a reply and without echoing a byte
# of its text:
#   - update carries a plain "message" (edited, channel, callback, and every
#     other update type is refused; allowed_updates asks for messages only)
#   - message.chat.type is exactly "private"
#   - message.chat.id equals the paired chat id
#   - message.from.id equals the paired captain user id, and is_bot is not true
#   - no forward marker, no via_bot, no sender_chat, no story
#   - text is a non-empty string within FM_TG_MAX_REQUEST_CHARS
#
# CRASH SAFETY: each accepted update is committed to state/tg/inbox/ BEFORE the
# update cursor advances, and the commit is a create-only claim. A crash between
# the commit and the cursor write replays the update, which then lands on the
# existing record and is skipped, so a message is never lost and never doubled.
#
# Usage: fm-tg-poll.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

TG_DIR=$(fm_tg_dir)
ERROR_FILE="$TG_DIR/poll.error"
REJECT_FILE="$TG_DIR/rejects"

MAX_CHARS=${FM_TG_MAX_REQUEST_CHARS:-4096}
case "$MAX_CHARS" in ''|*[!0-9]*) MAX_CHARS=4096 ;; esac
[ "$MAX_CHARS" -ge 1 ] 2>/dev/null && [ "$MAX_CHARS" -le 4096 ] 2>/dev/null || MAX_CHARS=4096

BATCH=${FM_TG_POLL_BATCH:-20}
case "$BATCH" in ''|*[!0-9]*) BATCH=20 ;; esac
[ "$BATCH" -ge 1 ] 2>/dev/null && [ "$BATCH" -le 100 ] 2>/dev/null || BATCH=20

POLL_TIMEOUT=${FM_TG_POLL_TIMEOUT:-10}
case "$POLL_TIMEOUT" in ''|*[!0-9]*) POLL_TIMEOUT=10 ;; esac
[ "$POLL_TIMEOUT" -le 20 ] 2>/dev/null || POLL_TIMEOUT=10
export FM_TG_HTTP_TIMEOUT="${FM_TG_HTTP_TIMEOUT:-$((POLL_TIMEOUT + 8))}"

# One diagnostic per distinct cause, repeated only after recovery, so a broken
# token cannot wake firstmate on every check cycle.
emit_error_once() {
  local msg=$1
  if fm_tg_private_file_valid "$ERROR_FILE" 600 \
    && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" | fm_tg_private_publish_stdin "$TG_DIR" "poll.error" 2>/dev/null || true
  printf 'tg-mode-error %s\n' "$msg"
}

clear_error() { rm -f -- "$ERROR_FILE" 2>/dev/null || true; }

# A refused update is counted, never quoted: the counter records how many
# unauthorized or unsupported updates were dropped and when, and nothing else.
record_reject() {
  local kind=$1 prior=0 now
  now=$(date +%s)
  if fm_tg_private_file_valid "$REJECT_FILE" 600; then
    prior=$(jq -r '.count // 0 | if type == "number" then tostring else "0" end' "$REJECT_FILE" 2>/dev/null) || prior=0
    case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  fi
  jq -cn --argjson count "$((prior + 1))" --argjson at "$now" --arg kind "$kind" \
    '{schema:"fm-telegram-rejects.v1", count:$count, last_kind:$kind, last_at:$at}' \
    | fm_tg_private_publish_stdin "$TG_DIR" "rejects" 2>/dev/null || true
}

cursor_read() {
  local file value
  file=$(fm_tg_cursor_file)
  fm_tg_private_file_valid "$file" 600 || { printf '0\n'; return 0; }
  IFS= read -r value < "$file" || { printf '0\n'; return 0; }
  case "$value" in
    ''|*[!0-9]*) printf '0\n'; return 0 ;;
  esac
  [ "${#value}" -le 19 ] || { printf '0\n'; return 0; }
  printf '%s\n' "$value"
}

cursor_write() {
  local value=$1
  printf '%s\n' "$value" | fm_tg_private_publish_stdin "$TG_DIR" "cursor"
}

wake_if_pending() {
  local pending
  pending=$(fm_tg_pending_count)
  [ "$pending" -gt 0 ] || return 0
  printf 'tg-message %s pending\n' "$pending"
}

fm_tg_config_load
[ "$FM_TG_CONFIGURED" = 1 ] || exit 0
[ "$FM_TG_ENABLED" = 1 ] || exit 0

command -v jq   >/dev/null 2>&1 || { emit_error_once "jq is not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { emit_error_once "curl is not installed"; exit 0; }

if ! fm_tg_token_load "$FM_TG_TOKEN_OWNER"; then
  emit_error_once "the stored bot token could not be read from the ${FM_TG_TOKEN_OWNER:-configured} owner"
  exit 0
fi

BODY_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-poll.XXXXXX") || exit 0
trap 'rm -f -- "$BODY_FILE"' EXIT

CURSOR=$(cursor_read)
OFFSET=$((CURSOR + 1))
PENDING=$(fm_tg_pending_count)
if [ "$PENDING" -ge "$FM_TG_INBOX_MAX" ]; then
  wake_if_pending
  exit 0
fi
AVAILABLE=$((FM_TG_INBOX_MAX - PENDING))
[ "$BATCH" -le "$AVAILABLE" ] || BATCH=$AVAILABLE
REPLY_AVAILABLE=$(fm_tg_send_capacity_remaining)
if [ "$REPLY_AVAILABLE" -le 0 ]; then
  wake_if_pending
  exit 0
fi
[ "$BATCH" -le "$REPLY_AVAILABLE" ] || BATCH=$REPLY_AVAILABLE

PAYLOAD_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-poll-req.XXXXXX") || exit 0
trap 'rm -f -- "$BODY_FILE" "$PAYLOAD_FILE"' EXIT
jq -cn --argjson offset "$OFFSET" --argjson limit "$BATCH" --argjson timeout "$POLL_TIMEOUT" \
  '{offset:$offset, limit:$limit, timeout:$timeout, allowed_updates:["message"]}' \
  > "$PAYLOAD_FILE" 2>/dev/null || exit 0

CODE=$(fm_tg_api getUpdates "$BODY_FILE" "$PAYLOAD_FILE")
API_RC=$?
if [ "$API_RC" -ne 0 ]; then
  case "$API_RC" in
    # A long-poll timeout is the normal quiet case, not an error worth waking for:
    # the next check cycle simply retries from the same cursor.
    28) wake_if_pending; exit 0 ;;
    # A local precondition failed - the stored token or the configured API host is
    # not usable - so no request was ever built. Say that, rather than blaming the
    # network for something re-running the setup will fix.
    2)  emit_error_once "the channel is misconfigured locally; re-run the channel setup"; exit 0 ;;
    *)  emit_error_once "the Telegram API could not be reached"; exit 0 ;;
  esac
fi

case "$CODE" in
  200) ;;
  401|403) emit_error_once "Telegram rejected the bot token; re-run the channel setup"; exit 0 ;;
  409) emit_error_once "another client is polling this bot, or a webhook is still registered; re-run the channel setup"; exit 0 ;;
  429) wake_if_pending; exit 0 ;;
  *)   emit_error_once "the Telegram API returned an unexpected status"; exit 0 ;;
esac

if ! jq -e '.ok == true and (.result | type) == "array"' "$BODY_FILE" >/dev/null 2>&1; then
  emit_error_once "the Telegram API returned an unreadable response"
  exit 0
fi
clear_error

# Classify every update in one pass. The output is strictly derived, bounded
# values - an integer update id, a fixed verdict token, and (only for an accepted
# update) the message fields - emitted as one COMPACT JSON object per line. jq's
# compact output escapes every newline inside a string, so one line is always
# exactly one record no matter what the captain typed.
CLASSIFIED=$(jq -c --argjson maxchars "$MAX_CHARS" --argjson user "$FM_TG_USER_ID" \
  --argjson chat "$FM_TG_CHAT_ID" '
  def is_int: type == "number" and floor == .;
  def verdict:
    . as $u
    | (.message // null) as $m
    | if ($u | has("edited_message")) or ($u | has("channel_post"))
         or ($u | has("edited_channel_post")) or ($u | has("callback_query"))
         or ($u | has("inline_query")) or ($u | has("my_chat_member"))
         or ($u | has("chat_member")) then "refused"
      elif $m == null or ($m | type) != "object" then "refused"
      elif ($m.chat.type // "") != "private" then "refused"
      elif (($m.chat.id | is_int) | not) or $m.chat.id != $chat then "refused"
      elif (($m.from.id | is_int) | not) or $m.from.id != $user then "refused"
      elif ($m.from.is_bot // false) == true then "refused"
      elif ($m | has("forward_origin")) or ($m | has("forward_from"))
        or ($m | has("forward_from_chat")) or ($m | has("forward_sender_name"))
        or ($m | has("forward_date")) or ($m | has("via_bot"))
        or ($m | has("sender_chat")) or ($m | has("story")) then "refused"
      elif ($m.text | type) != "string" then "unsupported"
      elif (($m.text | gsub("[[:space:]]"; "")) | length) == 0 then "unsupported"
      elif ($m.text | length) > $maxchars then "oversized"
      else "accept"
      end;
  .result
  | map(select(type == "object"))
  | map(select((.update_id | is_int)))
  | sort_by(.update_id)
  | .[]
  | . as $u
  | ($u | verdict) as $v
  | {
      update_id: $u.update_id,
      verdict: $v,
      message_id: (if $v == "accept" then ($u.message.message_id // 0) else 0 end),
      date: (if $v == "accept" then ($u.message.date // 0) else 0 end),
      text: (if $v == "accept" then $u.message.text else "" end)
    }
' "$BODY_FILE" 2>/dev/null) || CLASSIFIED=

MAX_SEEN=$CURSOR
NEW=0
NOW=$(date +%s)
COMMIT_FAILED=0
while IFS= read -r record; do
  [ -n "$record" ] || continue
  uid=$(printf '%s' "$record" | jq -r '.update_id' 2>/dev/null) || continue
  case "$uid" in ''|*[!0-9]*) continue ;; esac
  verdict=$(printf '%s' "$record" | jq -r '.verdict' 2>/dev/null) || continue
  rid="tg-$uid"
  fm_tg_request_id_valid "$rid" || continue
  rc=0
  case "$verdict" in
    accept)
      printf '%s' "$record" \
        | jq -c --arg rid "$rid" --argjson chat "$FM_TG_CHAT_ID" --argjson now "$NOW" \
          '{schema:"fm-telegram-request.v1", request_id:$rid, kind:"message",
            update_id:.update_id, message_id:.message_id, chat_id:$chat,
            sent_at:.date, received_at:$now, text:.text}' 2>/dev/null \
        | fm_tg_private_publish_stdin_once "$(fm_tg_inbox_dir)" "$rid.json"
      rc=$?
      ;;
    unsupported|oversized)
      # From the paired captain, but not something this channel handles. Record
      # the fact - never the content - so firstmate can answer once with a fixed
      # notice instead of leaving the captain wondering.
      jq -cn --arg rid "$rid" --arg kind "$verdict" --argjson uid "$uid" \
        --argjson chat "$FM_TG_CHAT_ID" --argjson now "$NOW" \
        '{schema:"fm-telegram-request.v1", request_id:$rid, kind:$kind,
          update_id:$uid, message_id:0, chat_id:$chat, sent_at:0,
          received_at:$now, text:""}' \
        | fm_tg_private_publish_stdin_once "$(fm_tg_inbox_dir)" "$rid.json"
      rc=$?
      ;;
    *)
      record_reject refused
      ;;
  esac
  if [ "$rc" = 2 ]; then
    # The record could not be committed, so the cursor must NOT pass this update:
    # the next poll re-fetches it instead of dropping the captain's message.
    COMMIT_FAILED=1
    break
  fi
  if [ "$rc" = 0 ] && [ "$verdict" != refused ]; then
    NEW=$((NEW + 1))
  fi
  [ "$uid" -gt "$MAX_SEEN" ] 2>/dev/null && MAX_SEEN=$uid
done <<EOF
$CLASSIFIED
EOF

if [ "$COMMIT_FAILED" = 1 ]; then
  emit_error_once "a captain message could not be stored locally"
fi

if [ "$MAX_SEEN" -gt "$CURSOR" ]; then
  cursor_write "$MAX_SEEN" || emit_error_once "the message cursor could not be recorded"
fi

[ "$NEW" -gt 0 ] && clear_error
wake_if_pending
exit 0
