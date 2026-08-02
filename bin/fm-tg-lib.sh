#!/usr/bin/env bash
# Shared configuration, secret, transport, and durable-record helpers for the
# Telegram captain channel (bin/fm-tg-setup.sh, bin/fm-tg-poll.sh,
# bin/fm-tg-inbox.sh, bin/fm-tg-reply.sh).
#
# The channel ships INERT: every entry point is a hard no-op until the operator
# stores a bot token, pairs the captain's numeric identity, and explicitly
# enables the channel. See docs/telegram-channel.md for the operator contract and
# docs/configuration.md for the schema.
#
# This file is sourced, never executed. It defines:
#   fm_tg_config_file / fm_tg_token_file / fm_tg_api_base
#   fm_tg_config_load           - read config/telegram.json into FM_TG_* vars
#   fm_tg_config_write          - atomically publish a new config object (stdin)
#   fm_tg_token_valid_shape     - the ONLY accepted bot-token grammar
#   fm_tg_token_store           - store the token (stdin) with the chosen owner
#   fm_tg_token_load            - resolve the token into FM_TG_TOKEN
#   fm_tg_token_remove          - drop the stored token
#   fm_tg_redact                - replace any token occurrence on stdin with ***
#   fm_tg_api                   - call one Bot API method, token never in argv
#   fm_tg_split_message         - split reply text (stdin) into bounded chunks
#   fm_tg_private_*             - atomic mode-0600 durable record primitives
#
# SECURITY INVARIANTS this library exists to hold:
#   - The bot token never appears in a process argument, a URL that is printed
#     or logged, an error message, a generated check script, or a durable record.
#     Every Bot API call passes its URL through a mode-0600 curl config file.
#   - Telegram text is DATA. Nothing here interpolates it into a shell command,
#     a path, or a generated script.
#   - Transport is outbound long polling only. Nothing here opens a listening
#     socket or registers a webhook.

# Accepted bot-token grammar: "<numeric bot id>:<opaque secret>". Enforced before
# the token is ever placed in a curl config file, so no quoting or escaping
# metacharacter can reach that file.
fm_tg_token_valid_shape() {
  local token=${1-}
  [[ "$token" =~ ^[0-9]{5,20}:[A-Za-z0-9_-]{30,64}$ ]]
}

fm_tg_config_file() {
  printf '%s\n' "${FM_TG_CONFIG_FILE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/telegram.json}"
}

fm_tg_token_file() {
  printf '%s\n' "${FM_TG_TOKEN_FILE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/telegram-token}"
}

fm_tg_state_dir() {
  printf '%s\n' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

# Bot API root. Overridable ONLY so deterministic tests can point the client at a
# loopback fake; production always uses Telegram's own host.
fm_tg_api_base() {
  local base=${FM_TG_API_BASE:-https://api.telegram.org}
  printf '%s\n' "${base%/}"
}

# The keychain account this home stores its token under, so two firstmate homes
# on one machine keep independent bots.
fm_tg_keychain_account() {
  local home=${FM_HOME:-} tag
  tag=$(printf '%s' "$home" | tr -c 'A-Za-z0-9._-' '_')
  printf 'firstmate-telegram:%s\n' "$tag"
}

fm_tg_keychain_service() {
  printf '%s\n' "${FM_TG_KEYCHAIN_SERVICE:-firstmate-telegram-bot}"
}

fm_tg_security_bin() {
  printf '%s\n' "${FM_TG_SECURITY_BIN:-security}"
}

# --- durable private-record primitives --------------------------------------
#
# Same shape as the X-mode connector's private artifacts: mode-0600 regular
# files with a single hard link, published by atomic rename inside a mode-0700
# directory on one device, so a concurrent reader never sees a half-written
# record and no symlink or hard-link swap can redirect a write.

fm_tg_file_stat() {  # <file> <darwin-fmt> <linux-fmt>
  if [ "$(uname)" = Darwin ]; then
    stat -f "$2" "$1" 2>/dev/null
  else
    stat -c "$3" "$1" 2>/dev/null
  fi
}

fm_tg_private_file_valid() {  # <file> <mode> [device]
  local file=$1 mode=$2 device=${3-} links f_mode f_device
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  links=$(fm_tg_file_stat "$file" %l %h) || return 1
  [ "$links" = 1 ] || return 1
  f_mode=$(fm_tg_file_stat "$file" %Lp %a) || return 1
  [ "$f_mode" = "$mode" ] || return 1
  [ -z "$device" ] && return 0
  f_device=$(fm_tg_file_stat "$file" %d %d) || return 1
  [ "$f_device" = "$device" ]
}

fm_tg_private_dir_prepare() {  # <dir> -> device id
  local dir=$1 mode device
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fi
  chmod 700 "$dir" 2>/dev/null || true
  mode=$(fm_tg_file_stat "$dir" %Lp %a) || return 1
  [ "$mode" = 700 ] || return 1
  device=$(fm_tg_file_stat "$dir" %d %d) || return 1
  printf '%s\n' "$device"
}

# Publish stdin atomically to one exact path with one exact mode, WITHOUT
# touching the parent directory's mode. Used for artifacts that live in a shared
# directory this channel does not own (config/telegram.json), where tightening
# the parent to 0700 would be an unwanted side effect on unrelated files.
fm_tg_publish_atomic() {  # <dest> <mode>
  local dest=$1 mode=$2 dir base tmp
  case "$mode" in 600|700) ;; *) return 1 ;; esac
  dir=${dest%/*}
  base=${dest##*/}
  [ "$dir" != "$dest" ] || dir=.
  [ -n "$base" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-tg.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_tg_private_file_valid "$tmp" "$mode"; then
    rm -f -- "$tmp"; return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fm_tg_private_file_valid "$dest" "$mode"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"; return 1
  fi
  fm_tg_private_file_valid "$dest" "$mode"
}

# Publish stdin as <dir>/<base>, replacing any existing valid private record.
fm_tg_private_publish_stdin() {  # <dir> <base>
  local dir=$1 base=$2 device tmp dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  device=$(fm_tg_private_dir_prepare "$dir") || return 1
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-tg.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" || ! chmod 600 "$tmp" 2>/dev/null \
    || ! fm_tg_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"; return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fm_tg_private_file_valid "$dest" 600 "$device"; then
    rm -f -- "$tmp"; return 1
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"; return 1
  fi
  fm_tg_private_file_valid "$dest" 600 "$device"
}

# Publish stdin as <dir>/<base> only if it does not already exist. The hard-link
# claim is atomic within the prepared directory, so a replayed Telegram update
# and a concurrent poll cannot both create the record. Returns 0 when THIS caller
# created it, 1 when a valid record already owns the path, 2 on failure.
#
# This is the crash-safety hinge for ingress: the inbox record is committed
# before the update cursor advances, so a crash in between replays the update
# and lands here as "already exists" instead of duplicating work.
fm_tg_private_publish_stdin_once() {  # <dir> <base>
  local dir=$1 base=$2 device tmp dest
  case "$base" in
    ''|.*|*/*) return 2 ;;
  esac
  device=$(fm_tg_private_dir_prepare "$dir") || return 2
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-tg.XXXXXX" 2>/dev/null) || return 2
  if ! cat > "$tmp" || ! chmod 600 "$tmp" 2>/dev/null \
    || ! fm_tg_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"; return 2
  fi
  if ln -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    fm_tg_private_file_valid "$dest" 600 "$device" && return 0
    rm -f -- "$dest"
    return 2
  fi
  rm -f -- "$tmp"
  fm_tg_private_file_valid "$dest" 600 "$device" && return 1
  return 2
}

# --- configuration ----------------------------------------------------------
#
# config/telegram.json (fm-telegram.v1), mode 0600, gitignored. Populates:
#   FM_TG_CONFIGURED  1 when a readable v1 config exists
#   FM_TG_ENABLED     1 only when "enabled": true
#   FM_TG_USER_ID     the captain's exact numeric Telegram user id
#   FM_TG_CHAT_ID     the exact private chat id ingress is bound to
#   FM_TG_BOT_ID / FM_TG_BOT_USERNAME  public bot identity, for redacted status
#   FM_TG_TOKEN_OWNER keychain | file
# Always returns 0; callers branch on FM_TG_CONFIGURED / FM_TG_ENABLED so a
# missing or malformed config stays a silent no-op rather than an error path.
fm_tg_config_load() {
  local file parsed
  FM_TG_CONFIGURED=0
  FM_TG_ENABLED=0
  FM_TG_USER_ID=
  FM_TG_CHAT_ID=
  FM_TG_BOT_ID=
  FM_TG_BOT_USERNAME=
  FM_TG_TOKEN_OWNER=
  file=$(fm_tg_config_file)
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  parsed=$(jq -r '
    def num($v): if ($v | type) == "number" and ($v | floor) == $v then ($v | tostring) else "" end;
    def str($v): if ($v | type) == "string" then $v else "" end;
    if .schema != "fm-telegram.v1" then "" else
      [ (if .enabled == true then "1" else "0" end),
        num(.user_id), num(.chat_id), num(.bot_id),
        (str(.bot_username) | select(test("^[A-Za-z0-9_]{0,64}$")) // ""),
        (str(.token_owner) | if . == "keychain" or . == "file" then . else "" end)
      ] | join("\u001f")
    end
  ' "$file" 2>/dev/null) || return 0
  [ -n "$parsed" ] || return 0
  # Unit separator, never a tab: bash collapses runs of IFS *whitespace*, so a
  # tab-joined record with an empty field (an unpaired channel has two) would
  # shift every later field into the wrong variable.
  # shellcheck disable=SC2034 # Every FM_TG_* field here is read by callers after sourcing.
  IFS=$'\037' read -r FM_TG_ENABLED FM_TG_USER_ID FM_TG_CHAT_ID FM_TG_BOT_ID \
    FM_TG_BOT_USERNAME FM_TG_TOKEN_OWNER <<EOF
$parsed
EOF
  # shellcheck disable=SC2034 # Read by callers (fm-tg-poll.sh, fm-tg-reply.sh, fm-tg-setup.sh).
  FM_TG_CONFIGURED=1
  # An identity-incomplete config can never be enabled: ingress has nothing to
  # bind the captain to, so it must refuse rather than accept any sender.
  if [ -z "$FM_TG_USER_ID" ] || [ -z "$FM_TG_CHAT_ID" ]; then
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    FM_TG_ENABLED=0
  fi
  return 0
}

# Atomically publish a new config object read on stdin.
fm_tg_config_write() {
  fm_tg_publish_atomic "$(fm_tg_config_file)" 600
}

# --- token owner ------------------------------------------------------------
#
# Preferred owner is the macOS login keychain, so the secret is not a readable
# file at all. The gitignored mode-0600 config/telegram-token is the explicit,
# documented WEAKER fallback (and the only option off macOS): anything that can
# read the home's config directory can read it.
#
# The token is written to `security` on STDIN through its prompt path, never as
# an argument, so it cannot appear in the process table.

fm_tg_token_store() {  # <owner>   token on stdin
  local owner=$1 token file
  IFS= read -r token || true
  fm_tg_token_valid_shape "$token" || return 2
  case "$owner" in
    keychain)
      command -v "$(fm_tg_security_bin)" >/dev/null 2>&1 || return 3
      printf '%s\n%s\n' "$token" "$token" \
        | "$(fm_tg_security_bin)" add-generic-password -U \
            -a "$(fm_tg_keychain_account)" -s "$(fm_tg_keychain_service)" -w \
            >/dev/null 2>&1 || return 4
      ;;
    file)
      file=$(fm_tg_token_file)
      printf '%s\n' "$token" \
        | fm_tg_private_publish_stdin "${file%/*}" "${file##*/}" || return 4
      ;;
    *) return 2 ;;
  esac
  return 0
}

# Resolve the token into FM_TG_TOKEN. Returns 0 with FM_TG_TOKEN set, or
# non-zero with it cleared. The value is never printed by this function.
fm_tg_token_load() {  # [owner]
  local owner=${1:-${FM_TG_TOKEN_OWNER:-}} token file
  FM_TG_TOKEN=
  case "$owner" in
    keychain)
      command -v "$(fm_tg_security_bin)" >/dev/null 2>&1 || return 1
      token=$("$(fm_tg_security_bin)" find-generic-password \
        -a "$(fm_tg_keychain_account)" -s "$(fm_tg_keychain_service)" -w 2>/dev/null) || return 1
      ;;
    file)
      file=$(fm_tg_token_file)
      fm_tg_private_file_valid "$file" 600 || return 1
      IFS= read -r token < "$file" || return 1
      ;;
    *) return 1 ;;
  esac
  token=${token%$'\r'}
  fm_tg_token_valid_shape "$token" || return 1
  FM_TG_TOKEN=$token
  return 0
}

fm_tg_token_remove() {  # <owner>
  local owner=$1 file
  case "$owner" in
    keychain)
      command -v "$(fm_tg_security_bin)" >/dev/null 2>&1 || return 0
      "$(fm_tg_security_bin)" delete-generic-password \
        -a "$(fm_tg_keychain_account)" -s "$(fm_tg_keychain_service)" >/dev/null 2>&1 || true
      ;;
    file)
      file=$(fm_tg_token_file)
      rm -f -- "$file" 2>/dev/null || true
      ;;
  esac
  return 0
}

# Filter stdin, replacing every occurrence of the resolved token with "***".
# Every diagnostic that could conceivably carry transport detail goes through
# this, so a curl or Bot API error can never leak the secret into a log, a
# status line, a wake payload, or captain chat.
fm_tg_redact() {
  local token=${FM_TG_TOKEN:-}
  if [ -z "$token" ]; then
    cat
    return 0
  fi
  TOKEN=$token awk '{ t = ENVIRON["TOKEN"]; n = length(t); if (n > 0) { out = ""; while ((i = index($0, t)) > 0) { out = out substr($0, 1, i - 1) "***"; $0 = substr($0, i + n) } $0 = out $0 } print }'
}

# --- transport --------------------------------------------------------------
#
# fm_tg_api <method> <body-file> [payload-file]
# Calls one Bot API method and prints the HTTP status code on stdout; the
# response body is written to <body-file>. A JSON <payload-file> makes it a POST.
#
# The request URL carries the bot token, so it is written to a mode-0600 curl
# config file and passed with -K: the token never reaches argv, and no caller
# ever has a URL string it could print. Requires fm_tg_token_load to have run.
#
# Bounded by construction: FM_TG_HTTP_TIMEOUT (default 20s) caps the whole call
# so a slow Bot API can never outlive the watcher's per-check budget.
# Exit: 0 with a printed code, 2 on a local precondition failure, 4 when curl
# itself failed (no HTTP status observed), 28 on a curl timeout.
fm_tg_api() {
  local method=$1 body_file=$2 payload_file=${3:-} cfg code rc timeout
  case "$method" in
    ''|*[!A-Za-z]*) return 2 ;;
  esac
  fm_tg_token_valid_shape "${FM_TG_TOKEN:-}" || return 2
  # The base and token are both interpolated into a curl config file, where a
  # quote, backslash, or newline would change the meaning of the line rather than
  # the value. The token grammar already excludes all three; check the base too.
  case "$(fm_tg_api_base)" in
    *[\"\\]*|*$'\n'*|*$'\r'*|'') return 2 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 2
  timeout=${FM_TG_HTTP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  cfg=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tg-req.XXXXXX") || return 2
  chmod 600 "$cfg" 2>/dev/null || { rm -f -- "$cfg"; return 2; }
  {
    printf 'url = "%s/bot%s/%s"\n' "$(fm_tg_api_base)" "$FM_TG_TOKEN" "$method"
    if [ -n "$payload_file" ]; then
      printf 'request = "POST"\n'
      printf 'header = "Content-Type: application/json"\n'
      printf 'data-binary = "@%s"\n' "$payload_file"
    fi
  } > "$cfg" || { rm -f -- "$cfg"; return 2; }
  # -s, never -S: curl's own error text can quote the effective URL, and that URL
  # carries the token. Callers get a return code and compose their own message.
  code=$(curl -s -m "$timeout" -o "$body_file" -w '%{http_code}' -K "$cfg" 2>/dev/null)
  rc=$?
  rm -f -- "$cfg"
  if [ "$rc" -ne 0 ]; then
    [ "$rc" = 28 ] && return 28
    return 4
  fi
  printf '%s\n' "$code"
  return 0
}

# --- outbound message splitting ---------------------------------------------
#
# Telegram caps one message at 4096 UTF-16 code units. Replies are sent as PLAIN
# text with no parse_mode, so there is no markup entity that a split could tear
# in half and no escaping hazard - the message body is delivered literally.
#
# fm_tg_split_message <limit> <cap>: read the reply on stdin, print a compact
# JSON array of at most <cap> chunks of at most <limit> characters each, packed
# on paragraph, line, and word boundaries and hard-split only for a single
# over-long word. When the reply needs more than <cap> chunks the last retained
# chunk is marked with an ellipsis, so truncation is visible rather than silent.
fm_tg_split_message() {
  jq -Rsc --argjson limit "$1" --argjson cap "$2" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def hardsplit($b): . as $s | [range(0; ($s|length); $b) as $i | $s[$i:$i+$b]];
    def wordsplit($b):
      (gsub("[[:space:]]+"; " ") | trim) as $norm
      | if ($norm | length) == 0 then []
        else
          [ $norm | split(" ")[] | if (length > $b) then hardsplit($b)[] else . end ] as $words
          | (reduce $words[] as $w ({chunks: [], cur: ""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand | length) <= $b then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $w end
            )) as $st
          | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end)
        end;
    def units:
      split("\n\n") | map(trim) | map(select(length > 0));
    def pack($us; $b):
      (reduce $us[] as $u ({chunks: [], cur: ""};
        if ($u | length) > $b then
          (if .cur != "" then .chunks += [.cur] | .cur = "" else . end)
          | .chunks += ($u | wordsplit($b))
        else
          (if .cur == "" then $u else .cur + "\n\n" + $u end) as $cand
          | if ($cand | length) <= $b then .cur = $cand
            else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $u end
        end
      )) as $st
      | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end);
    trim as $norm
    | if ($norm | length) == 0 then []
      elif ($norm | length) <= $limit then [$norm]
      else
        ($norm | units) as $us
        | pack($us; $limit) as $raw
        | if ($raw | length) > $cap
          then ($raw[0:$cap] | (.[($cap - 1)] |= (.[0:($limit - 1)] + "…")))
          else $raw end
      end
  '
}

# --- shared record locations ------------------------------------------------

# Every durable Telegram record lives under one mode-0700 subtree this channel
# owns outright, so nothing here has to tighten or reason about the permissions
# of the shared state directory. The watcher check is the one exception: the
# watcher looks for it at a fixed top-level name.
fm_tg_dir()         { printf '%s/tg\n' "$(fm_tg_state_dir)"; }
fm_tg_inbox_dir()   { printf '%s/tg/inbox\n'  "$(fm_tg_state_dir)"; }
fm_tg_archive_dir() { printf '%s/tg/inbox/archive\n' "$(fm_tg_state_dir)"; }
fm_tg_sent_dir()    { printf '%s/tg/sent\n'   "$(fm_tg_state_dir)"; }
fm_tg_outbox_dir()  { printf '%s/tg/outbox\n' "$(fm_tg_state_dir)"; }
fm_tg_cursor_file() { printf '%s/tg/cursor\n' "$(fm_tg_state_dir)"; }
fm_tg_check_file()  { printf '%s/fm-telegram.check.sh\n' "$(fm_tg_state_dir)"; }
fm_tg_trust_file()  { printf '%s/fm-telegram.check-trust\n' "$(fm_tg_state_dir)"; }

# A ledger key is always "tg-<update_id>" (the reply to that message),
# "tg-<update_id>.u<n>" (the nth later update on the work it started), or
# "event-<slug>" (an unprompted notice). All three are derived locally from
# validated integers or caller-supplied slugs, never from Telegram text. This is
# the one gate every record filename passes through.
fm_tg_request_id_valid() {
  local id=${1-}
  [[ "$id" =~ ^(tg-[0-9]{1,19}(\.u[0-9]{1,3})?|event-[A-Za-z0-9][A-Za-z0-9._-]{0,63})$ ]]
}

# The inbound request id itself, without any follow-up suffix.
fm_tg_base_request_id_valid() {
  local id=${1-}
  [[ "$id" =~ ^tg-[0-9]{1,19}$ ]]
}

# --- task <-> Telegram request link (state/<id>.meta backed) -----------------
#
# When a Telegram message starts real work, the task carries the message's
# identity so the outcome can be reported back to the same conversation later,
# from a different session, without anyone remembering anything:
#   tg_request=<request_id>   the message that asked for this work
#   tg_request_ts=<epoch>     when the link was made
#   tg_updates=<n>            captain-facing updates already sent against it
# The count is what makes each follow-up's ledger key distinct and stable, so a
# retried follow-up is refused as a duplicate while a genuinely new milestone is
# not. bin/fm-tg-link.sh owns the read/write/clear so nothing hand-edits meta.

fm_tg_meta_get() {  # <meta> <key>
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

fm_tg_meta_link_set() {  # <meta> <request_id> <epoch> [updates]
  local meta=$1 rid=$2 ts=$3 updates=${4:-0} dir base tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_tg_base_request_id_valid "$rid" || return 1
  case "$ts$updates" in ''|*[!0-9]*) return 1 ;; esac
  dir=${meta%/*}; base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-tg.XXXXXX") || return 1
  if ! { grep -vE '^tg_request=|^tg_request_ts=|^tg_updates=' "$meta" || true; } > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  {
    printf 'tg_request=%s\n' "$rid"
    printf 'tg_request_ts=%s\n' "$ts"
    printf 'tg_updates=%s\n' "$updates"
  } >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

fm_tg_meta_link_clear() {  # <meta>
  local meta=$1 dir base tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  dir=${meta%/*}; base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-tg.XXXXXX") || return 1
  if ! { grep -vE '^tg_request=|^tg_request_ts=|^tg_updates=' "$meta" || true; } > "$tmp"; then
    rm -f -- "$tmp"; return 1
  fi
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
}

# Count pending (unclaimed) inbound request records.
fm_tg_pending_count() {
  local dir n=0 f
  dir=$(fm_tg_inbox_dir)
  [ -d "$dir" ] || { printf '0\n'; return 0; }
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
