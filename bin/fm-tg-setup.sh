#!/usr/bin/env bash
# fm-tg-setup.sh - guarded setup, status, and removal for the Telegram captain
# channel. The channel does nothing until this script has been run to completion
# and the operator has explicitly enabled it.
#
# Usage:
#   fm-tg-setup.sh token [--owner keychain|file]   store the bot token (stdin)
#   fm-tg-setup.sh pair [--wait <seconds>]         learn the captain's identity
#   fm-tg-setup.sh enable                          start accepting messages
#   fm-tg-setup.sh disable                         stop polling, keep config
#   fm-tg-setup.sh status                          redacted channel state
#   fm-tg-setup.sh uninstall                       remove token and config
#
# The three setup steps are deliberately separate and ordered: token, pair,
# enable. Each refuses until its predecessor is complete, so a half-configured
# channel can never accept a message.
#
# THE TOKEN IS NEVER AN ARGUMENT. "token" reads it on stdin only:
#
#   pbpaste | bin/fm-tg-setup.sh token
#   bin/fm-tg-setup.sh token < /path/to/token-from-botfather
#
# It is stored in the macOS login keychain by default. --owner file writes the
# gitignored mode-0600 config/telegram-token instead; that is a WEAKER fallback,
# because anything that can read the home's config directory can read the token.
# It is the only option off macOS.
#
# Nothing here ever prints the token, puts it in a process argument, writes it to
# a log, or embeds it in a generated script. Confirmations name only the bot's
# public identity.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

STATE=$(fm_tg_state_dir)
CHECK=$(fm_tg_check_file)
TRUST=$(fm_tg_trust_file)

usage() { sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,32p'; exit "${1:-0}"; }
err()   { printf 'fm-tg-setup: %s\n' "$1" >&2; exit "${2:-1}"; }
note()  { printf '%s\n' "$1"; }

command -v jq   >/dev/null 2>&1 || err "jq is required"
command -v curl >/dev/null 2>&1 || err "curl is required"

# Read the existing config, or the empty defaults when there is none.
config_json() {
  local file
  file=$(fm_tg_config_file)
  if [ -f "$file" ] && [ ! -L "$file" ] \
    && jq -e '.schema == "fm-telegram.v1"' "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    jq -cn '{schema:"fm-telegram.v1", enabled:false, user_id:null, chat_id:null,
             bot_id:null, bot_username:null, token_owner:null, paired_at:null}'
  fi
}

config_merge() {  # merge filter on stdin-free jq expression in $1
  config_json | jq -c "$1" | fm_tg_config_write \
    || err "the channel configuration could not be written"
}

# Call one Bot API method and leave the parsed body in $API_BODY. Returns 0 only
# on a 200 with ok:true. Diagnostics never quote transport detail, because that
# detail can carry the request URL and the request URL carries the token.
API_BODY=
api_call() {  # <method> [payload-json]
  local method=$1 payload=${2:-} body_file payload_file code rc
  API_BODY=
  body_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-setup.XXXXXX") || return 1
  payload_file=
  if [ -n "$payload" ]; then
    payload_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-setup-req.XXXXXX") || { rm -f -- "$body_file"; return 1; }
    printf '%s' "$payload" > "$payload_file" || { rm -f -- "$body_file" "$payload_file"; return 1; }
  fi
  code=$(fm_tg_api "$method" "$body_file" "$payload_file")
  rc=$?
  [ -n "$payload_file" ] && rm -f -- "$payload_file"
  if [ "$rc" -ne 0 ]; then rm -f -- "$body_file"; return 1; fi
  if [ "$code" != 200 ] || ! jq -e '.ok == true' "$body_file" >/dev/null 2>&1; then
    rm -f -- "$body_file"
    API_BODY=$code
    return 2
  fi
  API_BODY=$(cat "$body_file")
  rm -f -- "$body_file"
  return 0
}

load_token_or_die() {
  fm_tg_config_load
  [ -n "${FM_TG_TOKEN_OWNER:-}" ] || err "no bot token is stored yet; run: bin/fm-tg-setup.sh token"
  fm_tg_token_load "$FM_TG_TOKEN_OWNER" \
    || err "the stored bot token could not be read from the $FM_TG_TOKEN_OWNER owner; re-run: bin/fm-tg-setup.sh token"
}

cmd_token() {
  local owner=keychain token prior_owner
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner=${2:?--owner needs a value}; shift 2 ;;
      *) err "unknown option: $1" ;;
    esac
  done
  case "$owner" in
    keychain)
      if [ "$(uname)" != Darwin ]; then
        if [ "${FM_TG_TEST_ALLOW_KEYCHAIN:-0}" != 1 ]; then
          err "the keychain owner needs macOS; use --owner file (a weaker, gitignored mode-0600 file) on this host"
        fi
        case "$(fm_tg_api_base)" in
          http://127.0.0.1:*) ;;
          *) err "the keychain owner needs macOS; use --owner file (a weaker, gitignored mode-0600 file) on this host" ;;
        esac
      fi
      ;;
    file) ;;
    *) err "unknown token owner: use keychain or file" ;;
  esac
  [ -t 0 ] && err "read the token from stdin, never from an argument: pbpaste | bin/fm-tg-setup.sh token"
  fm_tg_config_load
  prior_owner=${FM_TG_TOKEN_OWNER:-}
  IFS= read -r token || true
  token=${token%$'\r'}
  token=${token#"${token%%[![:space:]]*}"}
  token=${token%"${token##*[![:space:]]}"}
  if ! fm_tg_token_valid_shape "$token"; then
    # Never echo what was read: a mistyped paste may be some other secret.
    err "that does not look like a BotFather token (expected <digits>:<secret>); nothing was stored"
  fi
  FM_TG_TOKEN=$token
  if ! api_call getMe; then
    FM_TG_TOKEN=
    err "Telegram did not accept that token; nothing was stored"
  fi
  local bot_id bot_username
  bot_id=$(printf '%s' "$API_BODY" | jq -r '.result.id // empty')
  bot_username=$(printf '%s' "$API_BODY" | jq -r '.result.username // empty')
  case "$bot_id" in ''|*[!0-9]*) FM_TG_TOKEN=; err "Telegram returned an unreadable bot identity; nothing was stored" ;; esac
  case "$bot_username" in *[!A-Za-z0-9_]*) bot_username= ;; esac

  if ! printf '%s\n' "$token" | fm_tg_token_store "$owner"; then
    FM_TG_TOKEN=
    case "$owner" in
      keychain) err "the token could not be stored in the login keychain (it must be unlocked in an interactive session); re-run from a terminal, or use --owner file" ;;
      *) err "the token could not be stored" ;;
    esac
  fi
  FM_TG_TOKEN=
  if [ -n "$prior_owner" ] && [ "$prior_owner" != "$owner" ]; then
    if ! fm_tg_token_remove "$prior_owner"; then
      if fm_tg_token_remove "$owner"; then
        err "the previous $prior_owner credential could not be removed, so the owner change was rolled back; unlock or repair that owner and retry"
      fi
      err "neither the previous $prior_owner credential nor the new $owner credential could be confirmed removed; repair both owners before retrying"
    fi
  fi
  config_merge ".bot_id = ${bot_id} | .bot_username = \"${bot_username}\" | .token_owner = \"${owner}\" | .enabled = false"
  chmod 600 "$(fm_tg_config_file)" 2>/dev/null || true
  note "stored: bot @${bot_username:-unknown} (id ${bot_id}) - token held by the ${owner} owner, never printed"
  note ""
  note "next, from the phone you want to use:"
  note "  1. open Telegram and start a private chat with @${bot_username:-your bot}"
  note "  2. back here, run: bin/fm-tg-setup.sh pair"
  note "  3. send the one-time pairing command it prints"
}

cmd_pair() {
  local wait=${FM_TG_PAIR_WAIT:-60} deadline found=0 challenge expected search_offset=0 payload max_seen=0 matched_update=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) wait=${2:?--wait needs seconds}; shift 2 ;;
      *) err "unknown option: $1" ;;
    esac
  done
  case "$wait" in ''|*[!0-9]*) wait=60 ;; esac
  [ "$wait" -le 600 ] || wait=600
  load_token_or_die

  challenge=${FM_TG_PAIR_CHALLENGE:-}
  if [ -z "$challenge" ]; then
    challenge=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  case "$challenge" in ''|*[!A-Za-z0-9]*) FM_TG_TOKEN=; err "a one-time pairing challenge could not be generated" ;; esac
  [ "${#challenge}" -ge 8 ] && [ "${#challenge}" -le 32 ] \
    || { FM_TG_TOKEN=; err "a one-time pairing challenge could not be generated"; }
  expected="/start $challenge"
  note "send this one-time command to the bot from the captain's private chat:"
  note "  $expected"
  note "listening for that command (up to ${wait}s)..."
  deadline=$(( $(date +%s) + wait ))
  local picked user_id chat_id chat_type first_name
  user_id=''; chat_id=''; chat_type=''; first_name=''
  while :; do
    payload=$(jq -cn --argjson offset "$search_offset" \
      '{offset:$offset,limit:20,timeout:5,allowed_updates:["message"]}')
    if ! api_call getUpdates "$payload"; then
      FM_TG_TOKEN=
      err "Telegram could not be reached while pairing"
    fi
    max_seen=$(printf '%s' "$API_BODY" | jq -r '
      [ .result[]? | .update_id | select(type == "number") ] | max // 0 | tostring' 2>/dev/null) || max_seen=0
    case "$max_seen" in ''|*[!0-9]*) max_seen=0 ;; esac
    # Take the newest matching private-chat message from a human. Group and
    # channel traffic and anyone without the local challenge are ignored.
    picked=$(printf '%s' "$API_BODY" | jq -c --arg expected "$expected" '
      [ .result[]?
        | select((.message | type) == "object")
        | select((.message.chat.type // "") == "private")
        | select((.message.from.is_bot // false) != true)
        | select((.message.from.id | type) == "number" and (.message.chat.id | type) == "number")
        | select(.message.text == $expected)
      ] | first // empty' 2>/dev/null) || picked=
    if [ -n "$picked" ]; then
      matched_update=$(printf '%s' "$picked" | jq -r '.update_id')
      user_id=$(printf '%s' "$picked" | jq -r '.message.from.id')
      chat_id=$(printf '%s' "$picked" | jq -r '.message.chat.id')
      chat_type=$(printf '%s' "$picked" | jq -r '.message.chat.type')
      first_name=$(printf '%s' "$picked" | jq -r '.message.from.first_name // ""' | tr -cd 'A-Za-z0-9 ._-' | cut -c1-32)
      found=1
      break
    fi
    [ "$max_seen" -lt "$search_offset" ] || search_offset=$((max_seen + 1))
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 2
  done
  FM_TG_TOKEN=
  [ "$found" = 1 ] || err "the one-time pairing command did not arrive from a private chat; run pair again for a new command."
  [ "$chat_type" = private ] || err "that chat is not a private one-to-one chat; this channel supports private chats only"
  [[ "$user_id" =~ ^-?[0-9]{1,19}$ ]] || err "Telegram returned an unreadable sender identity"
  [[ "$chat_id" =~ ^-?[0-9]{1,19}$ ]] || err "Telegram returned an unreadable chat identity"
  [ "${chat_id#-}" = "$chat_id" ] || err "that chat id belongs to a group or channel; this channel supports private chats only"

  # Consume everything seen during pairing, so the /start that paired the channel
  # is not delivered again as the captain's first request.
  if [ "$matched_update" -gt 0 ]; then
    printf '%s\n' "$matched_update" | fm_tg_private_publish_stdin "$(fm_tg_dir)" "cursor" \
      || err "the message cursor could not be recorded"
  fi

  config_merge ".user_id = ${user_id} | .chat_id = ${chat_id} | .paired_at = $(date +%s) | .enabled = false"
  note "paired: ${first_name:-captain} - private chat only"
  note "  sender id ends ...${user_id: -4}, chat id ends ...${chat_id: -4}"
  note "  messages from any other sender or chat will be dropped without a reply."
  note ""
  note "the channel is still off. turn it on with: bin/fm-tg-setup.sh enable"
}

# The registered check is a byte-static shim: it pins this home and the poll
# script it was registered against, and carries no secret of any kind. The bot
# token is resolved by the poll script from its configured owner at run time, so
# reading this file reveals nothing.
write_check() {
  mkdir -p "$STATE"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# fm-telegram watcher check - polls Telegram for new captain messages and'
    printf '%s\n' '# wakes firstmate when one is pending. Generated and registered by'
    printf '%s\n' '# bin/fm-tg-setup.sh; it holds no token.'
    printf 'export FM_HOME=%q\n' "$FM_HOME"
    printf 'exec %q\n' "$FM_ROOT/bin/fm-tg-poll.sh"
  } > "$CHECK" || err "the Telegram watcher check could not be written"
  chmod 700 "$CHECK"
  "$SCRIPT_DIR/fm-check-register.sh" fm-telegram >/dev/null \
    || err "the Telegram watcher check could not be registered"
}

unregister_check() { rm -f -- "$CHECK" "$TRUST" 2>/dev/null || true; }

# Arming or disarming the check above changes whether this home has an inbound
# captain channel, which is exactly what bin/fm-cadence.sh keys the watcher check
# cadence off. Reconcile it in the same breath so the operator learns the cadence
# outcome - and the restart it needs - from the command they just ran, instead of
# waiting for the next session start to converge it silently.
reconcile_cadence() {
  local out
  out=$("$SCRIPT_DIR/fm-cadence.sh" reconcile 2>/dev/null) || true
  [ -n "$out" ] && note "  ${out#CADENCE: }"
  return 0
}

# What the operator should actually expect after a reconcile, read back from the
# file rather than assumed: a reconcile that failed must not leave a promise of
# 30-second pickup standing.
report_pickup() {
  if [ -f "$("$SCRIPT_DIR/fm-cadence.sh" path 2>/dev/null)" ]; then
    note "  firstmate reads this chat every 30 seconds."
  else
    note "  the fast check cadence is not armed, so pickup stays on the 300-second cadence until that is fixed."
  fi
}

cmd_enable() {
  fm_tg_config_load
  [ -n "${FM_TG_TOKEN_OWNER:-}" ] || err "no bot token is stored yet; run: bin/fm-tg-setup.sh token"
  [ -n "$FM_TG_USER_ID" ] && [ -n "$FM_TG_CHAT_ID" ] \
    || err "the captain's identity is not paired yet; run: bin/fm-tg-setup.sh pair"
  load_token_or_die
  api_call getMe || { FM_TG_TOKEN=; err "Telegram did not accept the stored token; re-run: bin/fm-tg-setup.sh token"; }
  # Pull-only by construction: drop any webhook so getUpdates is the sole
  # transport. A registered webhook would also make every poll fail with 409.
  api_call deleteWebhook '{"drop_pending_updates":false}' \
    || { FM_TG_TOKEN=; err "the webhook state could not be cleared; the channel was not enabled"; }
  FM_TG_TOKEN=

  # The poll script the generated check will exec must exist, or the check would
  # be registered against nothing.
  [ -x "$FM_ROOT/bin/fm-tg-poll.sh" ] \
    || err "bin/fm-tg-poll.sh is missing or not executable; the channel was not enabled"

  write_check
  config_merge '.enabled = true'
  note "enabled: this Telegram chat is now polled for your messages."
  reconcile_cadence
  report_pickup
  note "  transport is outbound long polling only; no port is opened and no webhook is registered."
  note "  this chat is not end-to-end encrypted - never send credentials, keys, or recovery codes through it."
}

cmd_disable() {
  fm_tg_config_load
  [ "$FM_TG_CONFIGURED" = 1 ] || { note "the Telegram channel is not configured; nothing to disable"; return 0; }
  unregister_check
  config_merge '.enabled = false'
  local pending
  pending=$(fm_tg_pending_count)
  note "disabled: polling stopped, the bot token and pairing are kept."
  reconcile_cadence
  if [ "$pending" -gt 0 ]; then
    note "  $pending already-received message(s) remain in the local queue and are still readable with: bin/fm-tg-inbox.sh list"
  else
    note "  no received messages are waiting."
  fi
  note "  re-enable with: bin/fm-tg-setup.sh enable"
}

cmd_uninstall() {
  fm_tg_config_load
  local pending cleanup_failed=0
  pending=$(fm_tg_pending_count)
  unregister_check
  # Before the token-removal steps below, which can abort: the channel is already
  # disarmed at this point, so the cadence must not be left fast on that path.
  reconcile_cadence
  fm_tg_token_remove keychain || cleanup_failed=1
  fm_tg_token_remove file || cleanup_failed=1
  if [ "$cleanup_failed" = 1 ]; then
    config_merge '.enabled = false'
    err "polling is stopped, but one or more token owners could not be confirmed empty; unlock or repair them and retry uninstall"
  fi
  rm -f -- "$(fm_tg_config_file)" 2>/dev/null \
    || err "the token owners are empty, but the channel configuration could not be removed"
  note "removed: the bot token, the pairing, and the channel configuration."
  note "  polling is stopped and no webhook was ever registered, so nothing remains reachable from outside."
  if [ "$pending" -gt 0 ]; then
    note "  $pending already-received message(s) are still on disk under the home's state directory; delete them by hand if you want them gone."
  fi
  note "  delete the bot itself in BotFather with /deletebot if you no longer want it to exist."
}

cmd_status() {
  fm_tg_config_load
  if [ "$FM_TG_CONFIGURED" != 1 ]; then
    note "Telegram channel: not configured (inert). Start with: bin/fm-tg-setup.sh token"
    return 0
  fi
  local token_state=absent registered=no pending
  if [ -n "${FM_TG_TOKEN_OWNER:-}" ] && fm_tg_token_load "$FM_TG_TOKEN_OWNER"; then
    token_state="stored in the $FM_TG_TOKEN_OWNER owner"
    FM_TG_TOKEN=
  elif [ -n "${FM_TG_TOKEN_OWNER:-}" ]; then
    token_state="recorded as $FM_TG_TOKEN_OWNER but UNREADABLE"
  fi
  fm_tg_private_file_valid "$CHECK" 700 && [ -f "$TRUST" ] && registered=yes
  pending=$(fm_tg_pending_count)
  note "Telegram channel"
  note "  bot:        @${FM_TG_BOT_USERNAME:-unknown} (id ${FM_TG_BOT_ID:-unknown})"
  note "  token:      $token_state"
  if [ -n "$FM_TG_USER_ID" ] && [ -n "$FM_TG_CHAT_ID" ]; then
    note "  paired to:  sender ...${FM_TG_USER_ID: -4} in private chat ...${FM_TG_CHAT_ID: -4}"
  else
    note "  paired to:  nobody yet - run: bin/fm-tg-setup.sh pair"
  fi
  note "  accepting:  $([ "$FM_TG_ENABLED" = 1 ] && echo yes || echo 'no (inert)')"
  note "  monitored:  $registered"
  note "  waiting:    $pending received message(s) not yet handled"
  if fm_tg_private_file_valid "$(fm_tg_dir)/poll.error" 600; then
    note "  last error: $(fm_tg_redact < "$(fm_tg_dir)/poll.error" 2>/dev/null)"
  fi
}

case "${1:-status}" in
  -h|--help) usage 0 ;;
  token)     shift; cmd_token "$@" ;;
  pair)      shift; cmd_pair "$@" ;;
  enable)    shift; cmd_enable "$@" ;;
  disable)   shift; cmd_disable "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  status)    shift; cmd_status "$@" ;;
  *)         usage 2 >&2 ;;
esac
