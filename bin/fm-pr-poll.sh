#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR.
# For an open, ready GitHub PR, the same single gh read also returns the body so
# up to eight tailnet preview links can be probed with one-second connect and
# two-second total timeouts.
# Tailnet links in prose outside fenced blocks count as previews, regardless of
# declaration wording. Repeated blockquote or list prefixes are normalized so
# their fences are removed too, while four-space-indented code stays excluded.
# The GitHub @tsv body field is decoded before extraction while preserving an
# already multiline body and escaped backslashes.
# A link that fails that first budget is retried once at two-second connect and
# five-second total timeouts, because a loaded host can push an otherwise healthy
# tailnet round trip past the first budget while the service answers in
# milliseconds. Both budgets are fixed, and preview probing stops without a
# verdict once it passes PREVIEW_DEADLINE_SECS, which keeps the work inside the
# watcher's per-check ceiling instead of trading one wrong alert for an
# unbounded wait.
# A link still failing after the retry is corroborated once against local
# evidence bound to that exact captain-facing authority: the loopback proxy
# target Tailscale currently serves for it must answer 200 with a body on the
# same path. Corroboration only defers - it records the failure and stays silent
# for one check interval - so the next failing poll wakes firstmate anyway. A
# missing or non-loopback serve mapping, an unreadable mapping, or a loopback
# target that does not answer alerts on the first failing poll instead.
# A newly detected failed preview emits one line naming the task and PR; the
# committed failed-link identity suppresses repeats until recovery or link change.
# Every other error is silent, so a failed forge lookup can never be read as a
# merge or dead preview.
# Preview probes resolve the link host directly to this machine's Tailscale IPv4
# address and never follow redirects, so they cannot escape to public services.
# The corroborating probe is accepted only against a http://127.0.0.1:<port>
# target read fresh from tailscale serve on every poll, so local evidence can
# never be borrowed from another preview or a stale mapping.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

# Probe budgets. The first pair is the captain-facing fast path; the second is
# the single bounded retry that absorbs a loaded tailnet round trip. The
# deadline covers preview probing only, measured from a baseline this script
# sets itself. It is checked before the retry and before corroboration, so the
# longest probing run is the deadline plus one of those steps, which leaves the
# forge read headroom under the default 30-second FM_CHECK_TIMEOUT.
PREVIEW_CONNECT_SECS=1
PREVIEW_MAX_SECS=2
PREVIEW_RETRY_CONNECT_SECS=2
PREVIEW_RETRY_MAX_SECS=5
PREVIEW_LOCAL_CONNECT_SECS=1
PREVIEW_LOCAL_MAX_SECS=2
PREVIEW_TAILSCALE_SECS=3
PREVIEW_DEADLINE_SECS=18

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  task=${FM_PR_POLL_TASK_ID:-}
  preview_state=${FM_PR_POLL_STATE:-}
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
  task=${0##*/}
  task=${task%.check.sh}
  preview_state=${data%/*}
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

task_valid() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

preview_marker=
preview_pending=
preview_suspect=
if task_valid "$task" && [ -d "$preview_state" ] && [ ! -L "$preview_state" ]; then
  preview_marker=$preview_state/$task.preview-outage
  preview_pending=$preview_state/$task.preview-outage-pending
  preview_suspect=$preview_state/$task.preview-suspect
fi

tailnet_ipv4_valid() {
  local ip=$1 a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]}
  b=${BASH_REMATCH[2]}
  c=${BASH_REMATCH[3]}
  d=${BASH_REMATCH[4]}
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] \
    && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

# Recovery, a link change, and every non-open-ready PR state retire the whole
# preview record for this task, including the unconfirmed-failure record, so a
# later failure starts from a clean slate rather than inheriting an old verdict.
preview_outage_clear() {
  [ -n "$preview_marker" ] || return 0
  if [ -f "$preview_marker" ] && [ ! -L "$preview_marker" ]; then
    rm -f -- "$preview_marker" 2>/dev/null || true
  fi
  if [ -f "$preview_pending" ] && [ ! -L "$preview_pending" ]; then
    rm -f -- "$preview_pending" 2>/dev/null || true
  fi
  if [ -f "$preview_suspect" ] && [ ! -L "$preview_suspect" ]; then
    rm -f -- "$preview_suspect" 2>/dev/null || true
  fi
}

# True when this exact PR and preview link already failed a previous poll while
# local evidence still corroborated them. That is the second consecutive
# captain-facing failure, so the deferral is spent and the wake is due.
preview_record_matches() {
  local record=$1 failed_link=$2 recorded_url recorded_link
  [ -n "$record" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  {
    IFS= read -r recorded_url || return 1
    IFS= read -r recorded_link || [ -n "$recorded_link" ] || return 1
  } < "$record" 2>/dev/null
  [ "$recorded_url" = "$url" ] && [ "$recorded_link" = "$failed_link" ]
}

preview_suspect_matches() {
  preview_record_matches "$preview_suspect" "$1"
}

preview_pending_matches() {
  preview_record_matches "$preview_pending" "$1"
}

preview_outage_clear_changed() {
  local failed_link=$1
  if { [ -f "$preview_marker" ] && [ ! -L "$preview_marker" ] \
      && ! preview_record_matches "$preview_marker" "$failed_link"; } \
    || { [ -f "$preview_pending" ] && [ ! -L "$preview_pending" ] \
      && ! preview_record_matches "$preview_pending" "$failed_link"; } \
    || { [ -f "$preview_suspect" ] && [ ! -L "$preview_suspect" ] \
      && ! preview_record_matches "$preview_suspect" "$failed_link"; }; then
    preview_outage_clear
  fi
}

preview_suspect_record() {
  local failed_link=$1 tmp
  [ -n "$preview_suspect" ] || return 1
  if { [ -e "$preview_suspect" ] || [ -L "$preview_suspect" ]; } \
    && { [ ! -f "$preview_suspect" ] || [ -L "$preview_suspect" ]; }; then
    return 1
  fi
  umask 077
  tmp=$(mktemp "$preview_state/.fm-preview-suspect.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$url" "$failed_link" > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$preview_suspect"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Run a read-only local command under a wall clock when a timeout tool is
# installed. Without one the watcher's FM_CHECK_TIMEOUT ceiling stays the only
# bound, which is why no probe budget below depends on this helper alone.
preview_bounded() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
  fi
}

# One bounded HTTP probe: success is exactly a 200 carrying a body, matching the
# captain's own definition of a usable preview. Extra curl arguments, such as
# the tailnet --resolve pin, are passed through ahead of the fixed budget.
preview_http_ok() {
  local connect=$1 max=$2 target=$3 result code bytes
  shift 3
  result=$(curl -q --noproxy '*' "$@" \
    --connect-timeout "$connect" --max-time "$max" -sS -o /dev/null \
    -w '%{http_code} %{size_download}' "$target" 2>/dev/null) || result='000 0'
  case "$result" in
    *' '*) code=${result%% *}; bytes=${result#* } ;;
    *) code=000; bytes=0 ;;
  esac
  case "$code" in
    [0-9][0-9][0-9]) ;;
    *) code=000 ;;
  esac
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  [ "$code" = 200 ] && [ "$bytes" -gt 0 ]
}

# Echo the loopback proxy target Tailscale currently serves for exactly this
# preview authority. The mapping is read fresh on every poll and matched on the
# full host:port with a whole-authority "/" handler, so evidence can never be
# borrowed from another preview, a sub-path mount, or a remembered mapping.
preview_serve_target() {
  local want=$1 serve line authority current='' handler rest target
  serve=$(preview_bounded "$PREVIEW_TAILSCALE_SECS" tailscale serve status 2>/dev/null) \
    || return 1
  while IFS= read -r line; do
    case "$line" in
      https://*)
        authority=${line#https://}
        authority=${authority%%[[:space:]]*}
        authority=${authority%%/*}
        case "$authority" in
          *:*) ;;
          *) authority=$authority:443 ;;
        esac
        current=$authority
        ;;
      '|--'*)
        [ "$current" = "$want" ] || continue
        rest=${line#'|--'}
        rest=${rest#"${rest%%[![:space:]]*}"}
        handler=${rest%%[[:space:]]*}
        [ "$handler" = / ] || continue
        rest=${rest#"$handler"}
        rest=${rest#"${rest%%[![:space:]]*}"}
        case "$rest" in
          proxy[[:space:]]*) ;;
          *) continue ;;
        esac
        target=${rest#proxy}
        target=${target#"${target%%[![:space:]]*}"}
        target=${target%%[[:space:]]*}
        printf '%s\n' "$target"
        return 0
        ;;
    esac
  done <<EOF
$serve
EOF
  return 1
}

# Evidence against alerting on one slow captain-facing probe, never evidence
# that an unreachable preview URL is healthy: it buys a single check interval.
# A missing, non-loopback, or unreadable mapping and a loopback target that does
# not answer all count as no corroboration, so the alert stays prompt whenever
# the local side is genuinely gone, replaced, or unmapped.
preview_local_evidence() {
  local preview_host=$1 port=$2 link_path=$3 target local_port
  target=$(preview_serve_target "$preview_host:$port") || return 1
  case "$target" in
    http://127.0.0.1:*) ;;
    *) return 1 ;;
  esac
  local_port=${target##*:}
  case "$local_port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || return 1
  preview_http_ok "$PREVIEW_LOCAL_CONNECT_SECS" "$PREVIEW_LOCAL_MAX_SECS" \
    "$target$link_path"
}

preview_outage_stage_new() {
  local failed_link=$1 tmp
  [ -n "$preview_marker" ] && [ -n "$preview_pending" ] || return 1
  if { [ -e "$preview_marker" ] || [ -L "$preview_marker" ]; } \
    && { [ ! -f "$preview_marker" ] || [ -L "$preview_marker" ]; }; then
    return 1
  fi
  if { [ -e "$preview_pending" ] || [ -L "$preview_pending" ]; } \
    && { [ ! -f "$preview_pending" ] || [ -L "$preview_pending" ]; }; then
    return 1
  fi
  umask 077
  tmp=$(mktemp "$preview_state/.fm-preview-outage.XXXXXX") || return 1
  if ! printf '%s\n%s' "$url" "$failed_link" > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -f "$preview_marker" ] && cmp -s "$tmp" "$preview_marker"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$preview_pending"; then
    rm -f -- "$tmp"
    return 1
  fi
}

probe_previews() {
  local body=$1 links link authority preview_host port local_tailnet_ip tailnet_ip
  local decoded_body link_path count
  task_valid "$task" || return 0
  # The header owns preview-declaration extraction mechanics.
  case "$body" in
    *$'\n'*) decoded_body=$body ;;
    *)
      decoded_body=$(printf '%s\n' "$body" | awk '
        {
          decoded = ""
          for (i = 1; i <= length($0); i++) {
            char = substr($0, i, 1)
            if (char != "\\" || i == length($0)) {
              decoded = decoded char
              continue
            }
            escaped = substr($0, ++i, 1)
            if (escaped == "n") decoded = decoded "\n"
            else if (escaped == "r") decoded = decoded "\r"
            else if (escaped == "t") decoded = decoded "\t"
            else if (escaped == "\\") decoded = decoded "\\"
            else decoded = decoded "\\" escaped
          }
          print decoded
        }
      ')
      ;;
  esac
  links=$(printf '%s\n' "$decoded_body" \
    | awk '
      function normalize_container(line, leading, rest, first, marker_end, i, padding) {
        while (1) {
          leading = 0
          while (leading < 4 && substr(line, leading + 1, 1) == " ") leading++
          if (leading > 3) return line
          rest = substr(line, leading + 1)
          if (substr(rest, 1, 1) == ">") {
            rest = substr(rest, 2)
            if (substr(rest, 1, 1) == " ") rest = substr(rest, 2)
            line = rest
            continue
          }
          first = substr(rest, 1, 1)
          marker_end = 0
          if ((first == "-" || first == "+" || first == "*") \
              && substr(rest, 2, 1) ~ /[[:space:]]/) {
            marker_end = 1
          } else if (first ~ /[0-9]/) {
            i = 1
            while (i <= 9 && substr(rest, i, 1) ~ /[0-9]/) i++
            if (i >= 2 && i <= 10 \
                && (substr(rest, i, 1) == "." || substr(rest, i, 1) == ")") \
                && substr(rest, i + 1, 1) ~ /[[:space:]]/) marker_end = i
          }
          if (!marker_end) return line
          rest = substr(rest, marker_end + 1)
          if (substr(rest, 1, 1) == "\t") {
            line = substr(rest, 2)
            continue
          }
          padding = 0
          while (substr(rest, padding + 1, 1) == " ") padding++
          if (padding < 1) return line
          if (padding <= 4) line = substr(rest, padding + 1)
          else line = substr(rest, 2)
        }
      }
      {
        source = $0
        if (!fenced || opener_container) raw = normalize_container(source)
        else raw = source
        leading = 0
        while (substr(raw, leading + 1, 1) == " ") leading++
        candidate = leading <= 3
        trimmed = substr(raw, leading + 1)
        delimiter = substr(trimmed, 1, 1)
        if (candidate && (delimiter == "`" || delimiter == "~")) {
          length_now = 0
          while (substr(trimmed, length_now + 1, 1) == delimiter) length_now++
          remainder = substr(trimmed, length_now + 1)
          valid_opener = delimiter != "`" || remainder !~ /`/
          if (!fenced && length_now >= 3 && valid_opener) {
            fenced = 1
            opener = delimiter
            opener_length = length_now
            opener_container = raw != source
            next
          }
          if (fenced && delimiter == opener && length_now >= opener_length \
              && remainder ~ /^[[:space:]]*$/) {
            fenced = 0
            opener = ""
            opener_length = 0
            opener_container = 0
            next
          }
        }
        if (fenced) next
        if (leading > 3) next
        print substr(raw, leading + 1)
      }
    ' \
    | grep -Eio 'https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.ts\.net(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&*+,;=%-]*)?' \
    | awk '!seen[$0]++' \
    | head -n 8) || true
  if [ -z "$links" ]; then
    preview_outage_clear
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 0
  command -v tailscale >/dev/null 2>&1 || return 0
  local_tailnet_ip=$(preview_bounded "$PREVIEW_TAILSCALE_SECS" tailscale ip -4 2>/dev/null) \
    || return 0
  tailnet_ipv4_valid "$local_tailnet_ip" || return 0
  tailnet_ip=$local_tailnet_ip
  if [ -n "${FM_PREVIEW_TAILNET_IP:-}" ]; then
    [ "$FM_PREVIEW_TAILNET_IP" = "$local_tailnet_ip" ] || return 0
    tailnet_ip=$FM_PREVIEW_TAILNET_IP
  fi

  # Own the probe deadline's baseline rather than inheriting one: bash adopts an
  # environment SECONDS, and an inherited value would silently skip every probe
  # below instead of bounding it.
  SECONDS=0
  count=0
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    count=$((count + 1))
    [ "$count" -le 8 ] || break
    authority=${link#https://}
    link_path=${authority#*/}
    case "$authority" in
      */*) link_path=/$link_path ;;
      *) link_path=/ ;;
    esac
    authority=${authority%%/*}
    case "$authority" in
      *:*) preview_host=${authority%:*}; port=${authority##*:} ;;
      *) preview_host=$authority; port=443 ;;
    esac
    case "$port" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
    preview_http_ok "$PREVIEW_CONNECT_SECS" "$PREVIEW_MAX_SECS" "$link" \
      --resolve "$preview_host:$port:$tailnet_ip" && continue
    # The captain-facing path missed the fast budget. Everything below stops
    # once the poll runs out of its deadline, leaving state and silence intact
    # so the next poll decides rather than this one guessing.
    [ "$SECONDS" -lt "$PREVIEW_DEADLINE_SECS" ] || return 0
    preview_http_ok "$PREVIEW_RETRY_CONNECT_SECS" "$PREVIEW_RETRY_MAX_SECS" "$link" \
      --resolve "$preview_host:$port:$tailnet_ip" && continue
    if preview_pending_matches "$link"; then
      printf 'preview-dead: task=%s pr=%s\n' "$task" "$url"
      return 0
    fi
    preview_outage_clear_changed "$link"
    [ "$SECONDS" -lt "$PREVIEW_DEADLINE_SECS" ] || return 0
    if preview_local_evidence "$preview_host" "$port" "$link_path" \
      && ! preview_suspect_matches "$link" \
      && preview_suspect_record "$link"; then
      return 0
    fi
    if preview_outage_stage_new "$link"; then
      printf 'preview-dead: task=%s pr=%s\n' "$task" "$url"
    fi
    return 0
  done <<EOF
$links
EOF
  preview_outage_clear
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    record=$(gh pr view "$url" --json state,isDraft,body \
      --jq '[.state, .isDraft, .body] | @tsv' 2>/dev/null) || exit 0
    case "$record" in
      *$'\t'*$'\t'*) ;;
      *) exit 0 ;;
    esac
    state=${record%%$'\t'*}
    rest=${record#*$'\t'}
    draft=${rest%%$'\t'*}
    body=${rest#*$'\t'}
    case "$state" in
      MERGED)
        preview_outage_clear
        printf '%s\n' merged
        ;;
      CLOSED) preview_outage_clear ;;
      OPEN)
        if [ "$draft" != false ]; then
          preview_outage_clear
          exit 0
        fi
        probe_previews "$body"
        ;;
      *) exit 0 ;;
    esac
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
