#!/usr/bin/env bash
# Create one Firstmate backlog item with creation-time task-ID validation.
# Usage:
#   fm-task-add.sh <id> "<title>" [tasks-axi add flags]
#   fm-task-add.sh "<title>" --mint [--prefix <prefix>] [tasks-axi add flags]
#
# Explicit IDs are validated before tasks-axi can mutate the backlog.
# Minting is staged in a temporary backlog so tasks-axi remains the owner of
# slug and uniqueness-suffix generation. If its optional prefix makes the
# minted ID too long, this wrapper trims only the head and preserves the final
# two-hex uniqueness suffix before validating and creating the real item.
# All tasks-axi add flags other than --mint and --prefix are passed through.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v tasks-axi >/dev/null 2>&1 || {
  echo "error: tasks-axi is required to create backlog items" >&2
  exit 1
}

MINT=0
for ARG in "$@"; do
  [ "$ARG" != --mint ] || MINT=1
done

if [ "$MINT" -eq 0 ]; then
  ID=${1-}
  fm_task_id_creation_check "$ID" || exit 2
  cd "$FM_HOME"
  exec tasks-axi add "$@"
fi

TITLE=${1-}
case "$TITLE" in
  ''|--*)
    echo 'error: minting requires a title first; use fm-task-add.sh "<title>" --mint' >&2
    exit 2
    ;;
esac
shift

PREFIX=
PREFIX_SET=0
FORWARD=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mint)
      ;;
    --prefix)
      [ "$PREFIX_SET" -eq 0 ] || { echo "error: --prefix may be passed only once" >&2; exit 2; }
      shift
      [ "$#" -gt 0 ] || { echo "error: --prefix requires a value" >&2; exit 2; }
      PREFIX=$1
      PREFIX_SET=1
      ;;
    --prefix=*)
      [ "$PREFIX_SET" -eq 0 ] || { echo "error: --prefix may be passed only once" >&2; exit 2; }
      PREFIX=${1#--prefix=}
      PREFIX_SET=1
      ;;
    *)
      FORWARD+=("$1")
      ;;
  esac
  shift
done

STORE_ARGS=()
for ((INDEX = 0; INDEX < ${#FORWARD[@]}; INDEX++)); do
  case "${FORWARD[$INDEX]}" in
    --file|--backend)
      NEXT=$((INDEX + 1))
      [ "$NEXT" -ge "${#FORWARD[@]}" ] || STORE_ARGS+=("${FORWARD[$INDEX]}" "${FORWARD[$NEXT]}")
      ;;
    --file=*|--backend=*)
      STORE_ARGS+=("${FORWARD[$INDEX]}")
      ;;
  esac
done

TASK_ADD_TMP=
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  [ -z "$TASK_ADD_TMP" ] || rm -rf -- "$TASK_ADD_TMP"
}
trap cleanup EXIT
TASK_ADD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-add.XXXXXX")

MINT_ARGS=("$TITLE" --mint --file "$TASK_ADD_TMP/backlog.md" --json)
if [ "$PREFIX_SET" -eq 1 ]; then
  MINT_ARGS+=(--prefix "$PREFIX")
fi

ATTEMPT=0
while [ "$ATTEMPT" -lt 256 ]; do
  MINT_JSON=$(tasks_axi add "${MINT_ARGS[@]}") || exit 1
  ID=$(printf '%s' "$MINT_JSON" | node -e '
    let input = "";
    process.stdin.on("data", chunk => { input += chunk; });
    process.stdin.on("end", () => {
      const parsed = JSON.parse(input);
      if (!parsed.task || typeof parsed.task.id !== "string") process.exit(2);
      process.stdout.write(parsed.task.id);
    });
  ') || {
    echo "error: tasks-axi mint did not return a task id" >&2
    exit 1
  }

  if ! fm_task_id_creation_valid "$ID"; then
    fm_pr_task_id_valid "$ID" || {
      fm_task_id_creation_check "$ID"
      exit 2
    }
    SUFFIX=${ID##*-}
    HEAD=${ID%-*}
    case "$SUFFIX" in
      [0-9a-f][0-9a-f]) ;;
      *)
        echo "error: overlong minted task id did not end in the expected two-hex uniqueness suffix" >&2
        exit 2
        ;;
    esac
    MAX_HEAD=$((FM_TASK_ID_MAX_LENGTH - ${#SUFFIX} - 1))
    HEAD=${HEAD:0:$MAX_HEAD}
    while :; do
      case "$HEAD" in
        *[-._]) HEAD=${HEAD%?} ;;
        *) break ;;
      esac
    done
    ID="$HEAD-$SUFFIX"
  fi

  fm_task_id_creation_check "$ID" || exit 2
  if ! tasks_axi show "$ID" ${STORE_ARGS[@]+"${STORE_ARGS[@]}"} >/dev/null 2>&1; then
    cd "$FM_HOME"
    exec tasks-axi add "$ID" "$TITLE" ${FORWARD[@]+"${FORWARD[@]}"}
  fi
  ATTEMPT=$((ATTEMPT + 1))
done

echo "error: could not mint an unused dispatchable task id after 256 suffixes" >&2
exit 1
