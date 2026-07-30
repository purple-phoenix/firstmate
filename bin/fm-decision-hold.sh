#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision exists.
# The invoking agent inventories unresolved decisions, assigns stable keys, and
# routes dependent work. This script supplies deterministic identities, creates
# and verifies structured tasks-axi captain holds, records completion attestation
# in the originating task's metadata, and closes a hold only after a durable
# decision record has been linked to existing dependent work.
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> --options-file <path> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision. Later review passes may add keys; a live task's
# metadata inventory is unioned idempotently. A post-teardown visual review can
# complete against the surviving report and holds without recreating task state.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, publishes
# a durable per-key resolution receipt under data/<origin>/decisions/<key>.resolved.md
# (survives Done retention), clears those dependency edges, and only then marks the
# hold Done. A failure before the final step leaves the captain hold open.
#
# `verify` / `complete` accept a hold that is actively queued, present as a Done
# backlog record with a resolution body, or absent from the live backlog when
# durable resolution evidence remains: the options document plus the
# `.resolved.md` receipt. When the live record was pruned and no receipt exists
# (legacy resolves that only wrote the backlog body), verify accepts an archived
# Done record that still carries the resolution body and logs an explicit
# legacy-attested acceptance. Open (queued-held) decisions never use that path.
# Retention pinning of Done captain holds is intentionally not used: tasks-axi
# owns Done prune, and the co-located receipt is the cleaner durable contract.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

validate_options_file() {  # <path> <title>
  local file=$1 title=$2 bytes document_title
  [ -f "$file" ] || fail "options file is not a regular file: $file"
  bytes=$(wc -c < "$file" | tr -d '[:space:]')
  [ "$bytes" -gt 0 ] && [ "$bytes" -le 131072 ] || fail "options file must contain 1 to 131072 bytes"
  document_title=$(sed -n 's/^# //p' "$file" | head -1)
  [ "$document_title" = "$title" ] || fail "options file title must match --title"
  awk '
    /^# / && !title { title = 1; next }
    /^## Options[[:space:]]*$/ { options = 1; next }
    title && !options && /[^[:space:]]/ { context = 1 }
    options && /^- (\[recommended\] )?.+[[:space:]]-[[:space:]].+/ { choices += 1 }
    END { exit !(title && context && options && choices > 0) }
  ' "$file" || fail "options file must include context and at least one option with its impact"
}

publish_options_file() {  # <origin> <key> <source>
  local origin=$1 key=$2 source=$3 directory target tmp
  directory="$DATA/$origin/decisions"
  target="$directory/$key.md"
  if [ -e "$target" ]; then
    cmp -s "$source" "$target" || fail "decision options already exist with different content: $target"
    return 0
  fi
  mkdir -p "$directory"
  chmod 700 "$directory" 2>/dev/null || true
  tmp=$(mktemp "$directory/.$key.XXXXXX") || fail "could not stage decision options"
  if ! cp "$source" "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    fail "could not stage decision options: $target"
  fi
  if mv -n "$tmp" "$target" && [ ! -e "$tmp" ] && [ -e "$target" ]; then
    return 0
  fi
  if [ -e "$target" ] && cmp -s "$source" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  fail "could not publish decision options: $target"
}

options_path() {  # <origin> <key>
  printf '%s/%s/decisions/%s.md\n' "$DATA" "$1" "$2"
}

resolution_receipt_path() {  # <origin> <key>
  printf '%s/%s/decisions/%s.resolved.md\n' "$DATA" "$1" "$2"
}

resolution_body_ok() {  # <text>
  case "$1" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

# Normalize a resolution body from either tasks-axi show (quoted, \n-escaped) or
# a durable on-disk receipt (literal newlines) into multiline plain text.
resolution_body_as_text() {  # <body>
  local body=$1
  case "$body" in
    '"Resolution recorded by fm-decision-hold.'*)
      body=${body#\"}
      body=${body%\"}
      # shellcheck disable=SC2059
      printf '%b' "$body"
      ;;
    'Resolution recorded by fm-decision-hold.'*)
      printf '%s' "$body"
      ;;
    *) return 1 ;;
  esac
}

# Write <text> to a temp file and cmp against <path>. Preserves trailing newlines
# (unlike $(cat), which strips them).
same_text_file() {  # <path> <text>
  local path=$1 text=$2 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-decision-hold.XXXXXX") || return 1
  printf '%s' "$text" > "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$path" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

publish_resolution_receipt() {  # <origin> <key> <body>
  local origin=$1 key=$2 body=$3 directory target tmp
  directory="$DATA/$origin/decisions"
  target=$(resolution_receipt_path "$origin" "$key")
  if [ -e "$target" ]; then
    same_text_file "$target" "$body" \
      || fail "resolution receipt already exists with different content: $target"
    return 0
  fi
  mkdir -p "$directory"
  chmod 700 "$directory" 2>/dev/null || true
  tmp=$(mktemp "$directory/.$key.resolved.XXXXXX") || fail "could not stage resolution receipt"
  if ! printf '%s' "$body" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    fail "could not stage resolution receipt: $target"
  fi
  if mv -n "$tmp" "$target" && [ ! -e "$tmp" ] && [ -e "$target" ]; then
    return 0
  fi
  if [ -e "$target" ] && same_text_file "$target" "$body"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  fail "could not publish resolution receipt: $target"
}

done_archive_path() {
  local configured=''
  if [ -f "$FM_HOME/.tasks.toml" ]; then
    configured=$(sed -n 's/^[[:space:]]*archive[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$FM_HOME/.tasks.toml" | head -1)
  fi
  [ -n "$configured" ] || configured=data/done-archive.md
  case "$configured" in
    /*) printf '%s\n' "$configured" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$configured" ;;
  esac
}

# Extract the body of an archived Done task by id. Prints the body on stdout and
# returns 0 when a matching Done captain-shaped archive entry is found.
archived_hold_body() {  # <hold-id>
  local id=$1 archive body='' in_task=0 line
  archive=$(done_archive_path)
  [ -f "$archive" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- [x] '"$id"' -'*)
        in_task=1
        body=''
        continue
        ;;
      '## '*|'- [x] '*|'- [ ] '*)
        if [ "$in_task" = 1 ]; then
          break
        fi
        continue
        ;;
    esac
    if [ "$in_task" = 1 ]; then
      case "$line" in
        '  '*)
          if [ -n "$body" ]; then
            body="${body}"$'\n'"${line#  }"
          else
            body="${line#  }"
          fi
          ;;
        '')
          [ -n "$body" ] && body="${body}"$'\n'
          ;;
      esac
    fi
  done < "$archive"
  [ "$in_task" = 1 ] || return 1
  printf '%s' "$body"
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
  if ! fm_task_id_creation_valid "$id"; then
    fm_pr_task_id_valid "$id" && [ "${#id}" -gt "$FM_TASK_ID_MAX_LENGTH" ] \
      || fail "captain hold $id has an invalid non-dispatchable identity"
  fi
}

verify_hold_resolved() {  # <hold-id> [origin] [key]
  local id=$1 origin=${2:-} key=${3:-} show state kind body receipt
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    body=$(show_field "$show" body)
    [ "$state" = "done" ] || return 1
    [ "$kind" = captain ] || return 1
    resolution_body_ok "$body" && return 0
    return 1
  fi
  # Live backlog may have pruned the Done record; accept a durable receipt.
  if [ -n "$origin" ] && [ -n "$key" ]; then
    receipt=$(resolution_receipt_path "$origin" "$key")
    if [ -f "$receipt" ]; then
      body=$(cat "$receipt")
      resolution_body_ok "$body" && return 0
    fi
  fi
  return 1
}

verify_hold_durable() {  # <origin> <key>
  local origin=$1 key=$2 id show state held kind hold_kind body receipt options archive_body
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    held=$(show_field "$show" held)
    kind=$(show_field "$show" kind)
    hold_kind=$(show_field "$show" hold_kind)
    body=$(show_field "$show" body)
    if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
      return 0
    fi
    if [ "$state" = "done" ] && [ "$kind" = captain ] && resolution_body_ok "$body"; then
      return 0
    fi
    fail "captain decision $id is neither actively held nor durably resolved"
  fi

  # Absent from the live backlog: only pruned RESOLVED evidence may satisfy the
  # gate. A still-open hold would still be queued in the live backlog.
  options=$(options_path "$origin" "$key")
  receipt=$(resolution_receipt_path "$origin" "$key")
  if [ -f "$receipt" ]; then
    body=$(cat "$receipt")
    if resolution_body_ok "$body"; then
      if [ -f "$options" ]; then
        printf 'fm-decision-hold: accepted durable resolution receipt for %s (options + receipt)\n' \
          "$id" >&2
      else
        printf 'fm-decision-hold: accepted durable resolution receipt for %s (receipt; options absent)\n' \
          "$id" >&2
      fi
      return 0
    fi
    fail "captain decision $id has a resolution receipt without a valid resolution body"
  fi

  # Legacy path: pre-receipt resolves left evidence only in the Done backlog body.
  # Accept an archived Done record that still carries the resolution body and log
  # an explicit attested override for what was accepted.
  if archive_body=$(archived_hold_body "$id"); then
    if resolution_body_ok "$archive_body"; then
      printf 'fm-decision-hold: legacy-attested: accepted pruned done record from archive for %s\n' \
        "$id" >&2
      return 0
    fi
    fail "captain decision $id is archived without a durable resolution body"
  fi

  fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 text recorded_digest recorded_routes
  text=$(resolution_body_as_text "$hold_body") \
    || fail "captain hold $id has no retry identity record"
  case "$text" in
    *$'\nRouted identities: '*$'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=$(printf '%s\n' "$text" | sed -n 's/^Decision digest: //p' | head -1)
  recorded_routes=$(printf '%s\n' "$text" | sed -n 's/^Routed identities: //p' | head -1)
  [ -n "$recorded_digest" ] || fail "captain hold $id has no retry identity record"
  [ -n "$recorded_routes" ] || fail "captain hold $id has an invalid retry identity record"
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' options_file='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --options-file) shift; options_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  [ -z "$options_file" ] || validate_options_file "$options_file" "$title"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
    [ -z "$options_file" ] || publish_options_file "$origin" "$key" "$options_file"
  else
    [ -n "$options_file" ] || fail "new captain hold $id requires --options-file"
    publish_options_file "$origin" "$key" "$options_file"
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$origin" "$key"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$origin" "$key"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$origin" "$key"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id" "$origin" "$key"; then
    if show=$(task_show "$id"); then
      hold_body=$(show_field "$show" body)
    else
      hold_body=$(cat "$(resolution_receipt_path "$origin" "$key")")
    fi
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  # Publish the durable receipt before closing the hold so a Done prune cannot
  # erase the only resolution evidence.
  publish_resolution_receipt "$origin" "$key" "$body"
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" "$origin" "$key" \
    || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
