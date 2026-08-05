#!/usr/bin/env bash
# tests/fm-check-cadence.test.sh - behavior regression for the watcher check
# cadence contract owned by bin/fm-cadence.sh and docs/configuration.md
# "Watcher check cadence".
#
# The contract under test: a home with an armed inbound captain channel (X-mode
# relay polling, the Telegram captain channel, the dashboard command-and-chat
# channel, or any combination) generates ONE config/check-cadence.env exporting
# FM_CHECK_INTERVAL=30; a home with none has no such file and keeps
# fm-watch.sh's 300s default. All channels share the single file, so several
# armed channels never produce two config owners or two supervision cycles.
#
# Nothing here touches a real bot, token, pairing, inbox, or reply ledger: the
# armed state of each channel is exactly the presence of its generated check
# shim, so these tests create and remove those shim files directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-check-cadence)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup; rm -rf "$TMP_ROOT"' EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADENCE="$ROOT/bin/fm-cadence.sh"

# One isolated home. Its config/ and state/ are overridden explicitly so no test
# can reach the operator's real home.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$home"
}

# Run a cadence command against one isolated home.
cadence() {
  local home=$1; shift
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" "$CADENCE" "$@" 2>&1
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

arm_x()        { : > "$1/state/x-watch.check.sh"; }
arm_telegram() { : > "$1/state/fm-telegram.check.sh"; }
arm_dash()     { : > "$1/state/fm-dash.check.sh"; }
disarm()       { rm -f "$1"/state/x-watch.check.sh "$1"/state/fm-telegram.check.sh "$1"/state/fm-dash.check.sh; }

# The cadence a watcher process would actually start with through the validated
# launch boundary.
effective_interval() {
  local home=$1
  # shellcheck disable=SC2016 # The child shell expands the cadence variable.
  cadence "$home" apply -- bash -c 'echo "${FM_CHECK_INTERVAL:-300}"'
}

assert_interval() {
  local home=$1 want=$2 msg=$3 got
  got=$(effective_interval "$home")
  [ "$got" = "$want" ] || fail "$msg (watcher would start at ${got}s, wanted ${want}s)"
}

# --- the matrix: which homes go fast ---------------------------------------

test_default_home_keeps_the_default_cadence() {
  local home out
  home=$(make_home default-off)
  out=$(cadence "$home" reconcile)
  [ -z "$out" ] || fail "a home with no captain channel must reconcile silently (got: $out)"
  assert_absent "$home/config/check-cadence.env" "no channel -> no cadence file"
  assert_interval "$home" 300 "a home with no captain channel must keep the default cadence"
  assert_contains "$(cadence "$home" status)" "armed: none" "status must report no armed channel"
  pass "a home with neither channel keeps the default 300s cadence and writes nothing"
}

test_telegram_only_home_goes_fast() {
  local home out
  home=$(make_home telegram-only)
  arm_telegram "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: 30s check cadence armed for the Telegram captain channel" \
    "arming Telegram must announce the 30s cadence"
  assert_present "$home/config/check-cadence.env" "Telegram alone must arm the cadence file"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/check-cadence.env" "cadence must be 30s"
  assert_interval "$home" 30 "a Telegram-only home must start its watcher at 30s"
  pass "a Telegram-only home runs its check on the 30s cadence"
}

test_x_only_home_goes_fast() {
  local home out
  home=$(make_home x-only)
  arm_x "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: 30s check cadence armed for X mode" \
    "arming X mode must announce the 30s cadence"
  assert_interval "$home" 30 "an X-only home must keep its existing 30s cadence"
  pass "an X-only home is unchanged: still the 30s cadence"
}

test_dashboard_only_home_goes_fast() {
  local home out
  home=$(make_home dash-only)
  arm_dash "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: 30s check cadence armed for the dashboard channel" \
    "arming the dashboard channel must announce the 30s cadence"
  assert_present "$home/config/check-cadence.env" "the dashboard channel alone must arm the cadence file"
  assert_interval "$home" 30 "a dashboard-only home must start its watcher at 30s"
  # Removing the dashboard check restores the default like any other channel.
  disarm "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: default 300s check cadence restored" \
    "disarming the dashboard channel must restore the default"
  assert_interval "$home" 300 "a disarmed dashboard home must return to 300s"
  pass "an installed writable dashboard is an armed captain channel on the 30s cadence"
}

test_both_channels_share_one_cadence_owner() {
  local home out files
  home=$(make_home both)
  arm_x "$home"
  arm_telegram "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "X mode and the Telegram captain channel" \
    "the transition line must name both armed channels"
  assert_interval "$home" 30 "a home with both channels must run at 30s"
  # Deterministically ONE config owner, not one per channel.
  files=$(find "$home/config" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$files" = 1 ] || fail "two armed channels must produce exactly one cadence file (found $files)"
  assert_present "$home/config/check-cadence.env" "the shared cadence file must be the one owner"
  # Reconciling again with both armed changes nothing and says nothing.
  out=$(cadence "$home" reconcile)
  [ -z "$out" ] || fail "a steady-state home with both channels must reconcile silently (got: $out)"
  pass "both channels enabled resolve to one cadence file, one cadence, no duplicate owner"
}

test_dropping_one_of_two_channels_stays_fast() {
  local home out
  home=$(make_home both-then-one)
  arm_x "$home"
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  # Telegram off, X still armed: the home must NOT fall back to 300s.
  rm -f "$home/state/fm-telegram.check.sh"
  out=$(cadence "$home" reconcile)
  [ -z "$out" ] || fail "releasing one of two channels must not announce a transition (got: $out)"
  assert_interval "$home" 30 "the remaining armed channel must keep the fast cadence"
  pass "releasing one channel while another stays armed keeps the 30s cadence"
}

# --- transitions ------------------------------------------------------------

test_reconcile_is_idempotent() {
  local home before after
  home=$(make_home idempotent)
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  before=$(shasum < "$home/config/check-cadence.env")
  cadence "$home" reconcile >/dev/null
  cadence "$home" reconcile >/dev/null
  after=$(shasum < "$home/config/check-cadence.env")
  [ "$before" = "$after" ] || fail "repeated reconciliation must leave the file byte-identical"
  pass "reconcile is idempotent and never rewrites an already-correct cadence file"
}

test_disarming_restores_the_default() {
  local home out
  home=$(make_home disarm)
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  disarm "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: default 300s check cadence restored" \
    "releasing the last channel must announce the restored default"
  assert_absent "$home/config/check-cadence.env" "releasing the last channel must remove the cadence file"
  assert_interval "$home" 300 "a disarmed home must return to the default cadence"
  out=$(cadence "$home" reconcile)
  [ -z "$out" ] || fail "a steady-state default home must reconcile silently (got: $out)"
  pass "releasing the last channel restores the default cadence, then stays silent"
}

test_transition_never_claims_a_running_watcher_rereads_it() {
  local home out
  home=$(make_home honest-transition)
  arm_telegram "$home"
  out=$(cadence "$home" reconcile)
  # fm-watch.sh reads FM_CHECK_INTERVAL once at process start. The transition line
  # must say so and hand over the harness repair instruction rather than implying
  # a live watcher picked the new cadence up.
  assert_contains "$out" "applies to the NEXT supervision cycle, not one already running" \
    "the arm line must not pretend a running watcher rereads the cadence"
  assert_contains "$out" "repair missing watcher supervision" \
    "the arm line must carry the harness supervision repair instruction"
  disarm "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "applies to the NEXT supervision cycle, not one already running" \
    "the release line must not pretend a running watcher rereads the cadence"
  pass "every transition states plainly that a running watcher keeps its old cadence"
}

test_transition_line_is_harness_aware() {
  local home out
  home=$(make_home harness-aware)
  arm_telegram "$home"
  # The repair instruction is delegated to the emitted supervision protocol rather
  # than hardcoded, so each primary harness gets its own restart mechanism. Only
  # the claude marker is settable from a test process (the others are detected by
  # process ancestry); per-harness rendering is covered exhaustively in
  # tests/fm-supervision-instructions.test.sh.
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" CLAUDECODE=1 "$CADENCE" reconcile 2>&1)
  assert_contains "$out" "Claude Code background task" \
    "a claude primary must get the claude repair mechanism"
  assert_not_contains "$out" "fm-watch-checkpoint.sh" \
    "a claude primary must not be handed codex's foreground checkpoint"
  assert_contains "$out" "bin/fm-watch-arm.sh" \
    "the repair instruction must use the cadence-validating watcher owner"
  assert_not_contains "$out" "source" \
    "the repair instruction must not source generated cadence bytes"
  pass "the transition's repair instruction follows the detected primary harness"
}

# --- migration off the pre-rename file --------------------------------------

test_legacy_cadence_file_is_migrated() {
  local home out
  home=$(make_home legacy-armed)
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  chmod 600 "$home/config/x-mode.env"
  arm_x "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "replacing the older config/x-mode.env" \
    "migration must be reported, not silent"
  assert_absent "$home/config/x-mode.env" "the pre-rename cadence file must be removed"
  assert_present "$home/config/check-cadence.env" "the current cadence file must replace it"
  assert_interval "$home" 30 "a migrated X home must still run at 30s"
  pass "an older home's config/x-mode.env is migrated to the single current owner"
}

test_legacy_cadence_file_is_removed_when_nothing_is_armed() {
  local home out
  home=$(make_home legacy-idle)
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  chmod 600 "$home/config/x-mode.env"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "removed the superseded config/x-mode.env" \
    "an idle home must report the removed legacy cadence"
  assert_absent "$home/config/x-mode.env" "the pre-rename cadence file must be removed"
  assert_absent "$home/config/check-cadence.env" "an idle home must not gain a cadence file"
  assert_interval "$home" 300 "a disarmed migrated home must run at the default cadence"
  assert_contains "$out" "applies to the NEXT supervision cycle, not one already running" \
    "the legacy-only release must be honest about an already-running watcher"
  assert_contains "$out" "repair missing watcher supervision" \
    "the legacy-only release must carry the harness supervision repair instruction"
  pass "a home with only the pre-rename cadence file returns to the default cadence"
}

# --- safety -----------------------------------------------------------------

test_symlinked_cadence_destination_is_refused() {
  local home target out
  home=$(make_home linked)
  target="$home/outside-sentinel"
  printf 'sentinel\n' > "$target"
  chmod 0640 "$target"
  ln -s "$target" "$home/config/check-cadence.env"
  arm_telegram "$home"
  out=$(cadence "$home" reconcile)
  assert_contains "$out" "CADENCE: failed to arm" "a linked cadence destination must be refused loudly"
  [ "$(cat "$target")" = sentinel ] || fail "reconcile wrote through the symlink to its target"
  [ "$(path_mode "$target")" = 640 ] || fail "reconcile changed the linked target's mode"
  pass "a symlinked cadence destination is refused without touching its target"
}

test_generated_file_is_private() {
  local home mode
  home=$(make_home private)
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  mode=$(path_mode "$home/config/check-cadence.env")
  [ "$mode" = 600 ] || fail "the generated cadence file must be mode 0600 (got $mode)"
  pass "the generated cadence file is owner-only"
}

test_verify_rejects_noncanonical_artifacts() {
  local home target body
  home=$(make_home verify-artifact)
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  cadence "$home" verify || fail "verify must accept the generated cadence artifact"
  body=$(cat "$home/config/check-cadence.env")

  chmod 0644 "$home/config/check-cadence.env"
  cadence "$home" verify >/dev/null 2>&1 && fail "verify must reject the wrong mode"
  cadence "$home" reconcile >/dev/null

  target="$home/cadence-hardlink"
  cp "$home/config/check-cadence.env" "$target"
  chmod 0600 "$target"
  rm -f "$home/config/check-cadence.env"
  ln "$target" "$home/config/check-cadence.env"
  cadence "$home" verify >/dev/null 2>&1 && fail "verify must reject a hard-linked artifact"

  rm -f "$home/config/check-cadence.env" "$target"
  printf '%s\n' "$body" > "$target"
  chmod 0600 "$target"
  ln -s "$target" "$home/config/check-cadence.env"
  cadence "$home" verify >/dev/null 2>&1 && fail "verify must reject a symlinked artifact"
  pass "verify accepts only the exact private single-link generated artifact"
}

test_apply_never_evaluates_artifact_bytes() {
  local home target sentinel got
  home=$(make_home apply-boundary)
  target="$home/cadence-target"
  sentinel="$home/executed"
  arm_telegram "$home"
  cadence "$home" reconcile >/dev/null
  # shellcheck disable=SC2016 # The child shell expands the cadence variable.
  got=$(cadence "$home" apply -- bash -c 'echo "${FM_CHECK_INTERVAL:-300}"')
  [ "$got" = 30 ] || fail "apply must export 30 for the validated artifact"

  rm -f "$home/config/check-cadence.env"
  printf 'touch %q\nexport FM_CHECK_INTERVAL=1\n' "$sentinel" > "$target"
  chmod 0600 "$target"
  ln -s "$target" "$home/config/check-cadence.env"
  # shellcheck disable=SC2016 # The child shell expands the cadence variable.
  got=$(cadence "$home" apply -- bash -c 'echo "${FM_CHECK_INTERVAL:-300}"')
  [ "$got" = 300 ] || fail "apply must keep the default for a rejected artifact"
  [ ! -e "$sentinel" ] || fail "apply evaluated rejected cadence bytes"

  rm -f "$home/config/check-cadence.env"
  ln "$target" "$home/config/check-cadence.env"
  # shellcheck disable=SC2016 # The child shell expands the cadence variable.
  got=$(cadence "$home" apply -- bash -c 'echo "${FM_CHECK_INTERVAL:-300}"')
  [ "$got" = 300 ] || fail "apply must reject a hard-linked artifact"
  [ ! -e "$sentinel" ] || fail "apply evaluated hard-linked cadence bytes"
  pass "apply exports only the validated fixed cadence without evaluating file bytes"
}

test_watcher_launch_owners_use_apply_boundary() {
  # shellcheck disable=SC2016 # The fixed-string needle must keep WATCH literal.
  assert_grep 'fm-cadence.sh" apply -- "$WATCH"' "$ROOT/bin/fm-watch-arm.sh" \
    "the arm owner must route watcher startup through cadence apply"
  # shellcheck disable=SC2016 # The fixed-string needle must keep SCRIPT_DIR literal.
  assert_grep 'fm-cadence.sh" apply -- "$SCRIPT_DIR/fm-watch.sh"' "$ROOT/bin/fm-watch-checkpoint.sh" \
    "the checkpoint owner must route watcher startup through cadence apply"
  pass "both standard watcher launch owners use the validated apply boundary"
}

test_cadence_file_carries_no_secret_and_no_channel_identity() {
  local home body
  home=$(make_home no-secret)
  arm_telegram "$home"
  arm_x "$home"
  cadence "$home" reconcile >/dev/null
  body=$(cat "$home/config/check-cadence.env")
  case "$body" in
    *token*|*TOKEN*|*chat_id*|*user_id*|*bot_id*|*bot_username*|*FMX_PAIRING*)
      fail "the cadence file must carry no channel identity or secret" ;;
  esac
  # It must export the cadence and nothing else executable.
  [ "$(grep -cv '^#' <<<"$body")" = 1 ] \
    || fail "the cadence file must contain exactly one non-comment line"
  [ "$(grep -v '^#' <<<"$body")" = "export FM_CHECK_INTERVAL=30" ] \
    || fail "the single non-comment line must be exactly the cadence export"
  pass "the generated cadence file exports only the interval - no secret, no identity"
}

test_path_command_needs_no_home_state() {
  local home out
  home="$TMP_ROOT/path-only"
  mkdir -p "$home"
  # `path` is on the hot path of guards and turn-end hooks: it must answer from
  # constants alone, with no config/ or state/ present and no channel armed.
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" "$CADENCE" path)
  [ "$out" = "$home/config/check-cadence.env" ] \
    || fail "path must resolve from the home's config dir alone (got: $out)"
  pass "the path lookup answers from constants, with no home state required"
}

test_default_home_keeps_the_default_cadence
test_telegram_only_home_goes_fast
test_x_only_home_goes_fast
test_dashboard_only_home_goes_fast
test_both_channels_share_one_cadence_owner
test_dropping_one_of_two_channels_stays_fast
test_reconcile_is_idempotent
test_disarming_restores_the_default
test_transition_never_claims_a_running_watcher_rereads_it
test_transition_line_is_harness_aware
test_legacy_cadence_file_is_migrated
test_legacy_cadence_file_is_removed_when_nothing_is_armed
test_symlinked_cadence_destination_is_refused
test_generated_file_is_private
test_verify_rejects_noncanonical_artifacts
test_apply_never_evaluates_artifact_bytes
test_watcher_launch_owners_use_apply_boundary
test_cadence_file_carries_no_secret_and_no_channel_identity
test_path_command_needs_no_home_state
