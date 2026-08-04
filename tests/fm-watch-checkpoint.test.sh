#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_checkpoint_applies_only_validated_cadence() {
  local home out err status target sentinel

  home=$(make_home valid-cadence)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/interval.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'interval=%s\n' "${FM_CHECK_INTERVAL:-300}"
SH
  chmod 0700 "$home/state/interval.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" interval >/dev/null \
    || fail "could not register valid-cadence checkpoint check"
  : > "$home/state/fm-telegram.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-cadence.sh" reconcile >/dev/null \
    || fail "could not generate valid checkpoint cadence"
  rm -f "$home/state/fm-telegram.check.sh"
  status=0
  ( unset FM_CHECK_INTERVAL; FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
      "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" ) || status=$?
  expect_code 0 "$status" "valid cadence checkpoint exit"
  assert_contains "$(cat "$out")" "interval=30" "checkpoint did not apply the validated fast cadence"

  home=$(make_home refused-cadence)
  out="$home/out.txt"
  err="$home/err.txt"
  target="$home/untrusted-cadence"
  sentinel="$home/executed"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/interval.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'interval=%s\n' "${FM_CHECK_INTERVAL:-300}"
SH
  chmod 0700 "$home/state/interval.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" interval >/dev/null \
    || fail "could not register refused-cadence checkpoint check"
  printf 'touch %s\nexport FM_CHECK_INTERVAL=30\n' "$sentinel" > "$target"
  chmod 0600 "$target"
  ln -s "$target" "$home/config/check-cadence.env"
  status=0
  ( unset FM_CHECK_INTERVAL; FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
      "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" ) || status=$?
  expect_code 0 "$status" "refused cadence checkpoint exit"
  assert_contains "$(cat "$out")" "interval=300" "checkpoint applied a rejected cadence artifact"
  assert_absent "$sentinel" "checkpoint evaluated rejected cadence bytes"
  pass "checkpoint applies valid cadence and refuses untrusted cadence bytes"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_checkpoint_applies_only_validated_cadence
test_existing_singleton_watcher_is_not_success
