#!/usr/bin/env bash
# Regression coverage for Firstmate backlog creation and minted task-ID fitting.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Sourced for the task-id validators only. Deliberately not followed statically:
# bin/fm-lint.sh's source-graph boundary keeps production context out of tests
# that do not need callback or variable interop.
# shellcheck source=/dev/null disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

ADD="$ROOT/bin/fm-task-add.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-add)

command -v tasks-axi >/dev/null 2>&1 || {
  echo "skip: tasks-axi not found"
  exit 0
}

json_id() {
  node -e '
    let input = "";
    process.stdin.on("data", chunk => { input += chunk; });
    process.stdin.on("end", () => process.stdout.write(JSON.parse(input).task.id));
  '
}

test_overlong_mint_is_dispatchable() {
  local backlog out id title
  backlog="$TMP_ROOT/minted.md"
  title="Make AstroAI Admin usage focused and privacy preserving across every administrator workflow"
  out=$("$ADD" "$title" --mint --prefix astroai-admin-privacy --file "$backlog" --json) \
    || fail "overlong mint failed at creation time"
  id=$(printf '%s' "$out" | json_id) || fail "mint result was not valid JSON"
  [ "${#id}" -eq "$FM_TASK_ID_MAX_LENGTH" ] \
    || fail "fitted mint length was ${#id}, expected $FM_TASK_ID_MAX_LENGTH"
  fm_task_id_creation_valid "$id" || fail "fitted mint was not dispatchable"
  case "$id" in
    *-[0-9a-f][0-9a-f]) ;;
    *) fail "fitted mint did not preserve its two-hex uniqueness suffix" ;;
  esac
  tasks-axi show "$id" --file "$backlog" >/dev/null \
    || fail "fitted mint was not written to the requested backlog"
  pass "overlong tasks-axi mint is fitted to a dispatchable ID"
}

test_creation_boundaries() {
  local backlog id64 id65 out rc
  backlog="$TMP_ROOT/boundary.md"
  id64=$(printf '%064d' 0 | tr 0 a)
  id65="${id64}a"

  "$ADD" "$id64" "boundary passes" --file "$backlog" >/dev/null \
    || fail "64-character task ID was rejected"
  fm_task_id_creation_valid "$id64" || fail "64-character validator boundary was rejected"

  set +e
  out=$("$ADD" "$id65" "boundary fails" --file "$backlog" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "65-character task ID returned $rc instead of 2"
  assert_contains "$out" "task id is 65 characters; maximum is 64" \
    "65-character creation failure was not clear"
  ! fm_task_id_creation_valid "$id65" || fail "65-character validator boundary was accepted"
  ! tasks-axi show "$id65" --file "$backlog" >/dev/null 2>&1 \
    || fail "65-character task ID reached the backlog"
  pass "creation validator accepts 64 and clearly rejects 65 before mutation"
}

test_default_home_and_empty_mint_flags() {
  local home caller out id
  home="$TMP_ROOT/default-home"
  caller="$TMP_ROOT/unrelated-caller"
  mkdir -p "$home/data" "$caller"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  out=$(cd "$caller" && FM_HOME="$home" "$ADD" "Mint without optional flags" --mint --json) \
    || fail "mint without optional flags failed outside the active home"
  id=$(printf '%s' "$out" | json_id) || fail "default-home mint result was not valid JSON"
  tasks-axi show "$id" --file "$home/data/backlog.md" >/dev/null \
    || fail "mint did not write to the active home backlog"
  [ ! -e "$caller/data/backlog.md" ] \
    || fail "mint wrote a backlog relative to the caller directory"
  pass "empty mint flags and active-home backlog selection are safe"
}

test_overlong_mint_is_dispatchable
test_creation_boundaries
test_default_home_and_empty_mint_flags
