#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR.
# For an open, ready GitHub PR, the same single gh read also returns the body so
# up to eight tailnet preview links can be probed with one-second connect and
# two-second total timeouts.
# A failed preview emits one line naming the task and PR; every other error is
# silent, so a failed forge lookup can never be read as a merge or dead preview.
# Preview probes resolve the link host directly to this machine's Tailscale IPv4
# address and never follow redirects, so they cannot escape to public services.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

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
if task_valid "$task" && [ -d "$preview_state" ] && [ ! -L "$preview_state" ]; then
  preview_marker=$preview_state/$task.preview-outage
  preview_pending=$preview_state/$task.preview-outage-pending
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

preview_outage_clear() {
  [ -n "$preview_marker" ] || return 0
  if [ -f "$preview_marker" ] && [ ! -L "$preview_marker" ]; then
    rm -f -- "$preview_marker" 2>/dev/null || true
  fi
  if [ -f "$preview_pending" ] && [ ! -L "$preview_pending" ]; then
    rm -f -- "$preview_pending" 2>/dev/null || true
  fi
}

preview_outage_stage_new() {
  local body=$1 tmp
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
  if ! printf '%s\n%s' "$url" "$body" > "$tmp" || ! chmod 0600 "$tmp"; then
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
  local result code bytes count
  task_valid "$task" || return 0
  links=$(printf '%s\n' "$body" \
    | grep -Eio 'https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.ts\.net(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&*+,;=%-]*)?' \
    | awk '!seen[$0]++' \
    | head -n 8) || true
  if [ -z "$links" ]; then
    preview_outage_clear
    return 0
  fi
  command -v curl >/dev/null 2>&1 || return 0
  command -v tailscale >/dev/null 2>&1 || return 0
  local_tailnet_ip=$(tailscale ip -4 2>/dev/null) || return 0
  tailnet_ipv4_valid "$local_tailnet_ip" || return 0
  tailnet_ip=$local_tailnet_ip
  if [ -n "${FM_PREVIEW_TAILNET_IP:-}" ]; then
    [ "$FM_PREVIEW_TAILNET_IP" = "$local_tailnet_ip" ] || return 0
    tailnet_ip=$FM_PREVIEW_TAILNET_IP
  fi

  count=0
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    count=$((count + 1))
    [ "$count" -le 8 ] || break
    authority=${link#https://}
    authority=${authority%%/*}
    case "$authority" in
      *:*) preview_host=${authority%:*}; port=${authority##*:} ;;
      *) preview_host=$authority; port=443 ;;
    esac
    case "$port" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
    result=$(curl -q --noproxy '*' --resolve "$preview_host:$port:$tailnet_ip" \
      --connect-timeout 1 --max-time 2 -sS -o /dev/null \
      -w '%{http_code} %{size_download}' "$link" 2>/dev/null) || result='000 0'
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
    if [ "$code" != 200 ] || [ "$bytes" -eq 0 ]; then
      if preview_outage_stage_new "$body"; then
        printf 'preview-dead: task=%s pr=%s\n' "$task" "$url"
      fi
      return 0
    fi
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
