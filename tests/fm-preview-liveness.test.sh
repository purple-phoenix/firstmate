#!/usr/bin/env bash
# Preview-liveness coverage for the authenticated per-task PR watcher.
#
# The watcher itself already has coverage proving any non-empty authenticated
# PR-poll result becomes a check wake.
# This suite owns the preview-specific contract: one GitHub read supplies state,
# draft status, and body; tailnet links outside fenced blocks on open ready PRs
# are probed; curl is pinned to this host's tailnet IPv4 address with short
# timeouts; a non-200 or empty response emits one task-and-PR wake line; and a
# healthy preview stays silent.
# It also owns the false-alert boundary: a captain-facing probe that misses the
# fast budget is retried once and then corroborated against the loopback target
# Tailscale serves for that exact preview, which defers a single check interval
# and never suppresses a second failure, a dead or replaced listener, or an
# absent, non-loopback, or mismatched serve mapping.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-preview-liveness)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
GH_LOG="$TMP_ROOT/gh.log"
CURL_LOG="$TMP_ROOT/curl.log"
TAILSCALE_LOG="$TMP_ROOT/tailscale.log"
CURL_SEQ="$TMP_ROOT/curl.seq"
DEADLINE_ENV="$TMP_ROOT/deadline.bash"
DEADLINE_MARKER="$TMP_ROOT/deadline-crossed"
SUSPECT="$TMP_ROOT/preview-task.preview-suspect"
URL=https://github.com/example/preview-app/pull/42
# The serve mapping this host publishes for the preview authority used below.
HEALTHY_SERVE='https://preview.tailnet.ts.net:5443 (tailnet only)
|-- / proxy http://127.0.0.1:5443'
# The forge returns the body as one tab-separated field with newlines escaped,
# so these fixtures carry literal backslash-n exactly as the poll receives them.
# FENCED_EVIDENCE_BODY is the shape that made this repository's own PR monitor a
# fixture host: an intent section plus a details block whose fenced transcript
# quotes a probe command, and no preview declaration anywhere.
# shellcheck disable=SC2016  # Fixture body text quoted verbatim; nothing expands.
FENCED_EVIDENCE_BODY='## Intent\n\nStop false preview alerts under host load.\n\n<details>\n<summary>Evidence: exact durable watcher wake, probes, and committed state</summary>\n\n```text\nPINNED PREVIEW PROBE\n-q --noproxy * --resolve fixture.tailnet.ts.net:9443:100.89.232.70 --connect-timeout 1 --max-time 2 -sS -o /dev/null -w %{http_code} %{size_download} https://fixture.tailnet.ts.net:9443/\nWATCHER OUTPUT\npreview-dead: task=preview-task pr=https://github.com/example/preview-app/pull/42\n```\n</details>\n'
FOUR_BACKTICK_BODY='````text\nA nested Markdown example follows.\n```sh\ncurl https://fixture.tailnet.ts.net:9443/\n```\n````\nPreview URL: https://preview.tailnet.ts.net:5443/\n'
LITERAL_BACKSLASH_N_BODY='```text\ntranscript preserves the two characters \\n```\nhttps://fixture.tailnet.ts.net:9443/\n```\n'
INDENTED_NON_FENCE_BODY='    ```example\nPreview URL: https://preview.tailnet.ts.net:5443/\n'
BACKTICK_INFO_NON_FENCE_BODY='```example`info\nPreview URL: https://preview.tailnet.ts.net:5443/\n'
BLOCKQUOTED_FENCE_BODY='> ```text\n> https://fixture.tailnet.ts.net:9443/\n> ````\n'
BLOCKQUOTED_DECLARATION_BODY='> Preview URL: https://preview.tailnet.ts.net:5443/\n'
LIST_CONTAINER_BODY='- Preview URL: https://preview.tailnet.ts.net:5443/\n'
CONTAINER_LIKE_CODE_BODY='```text\n- ```\nhttps://fixture.tailnet.ts.net:9443/\n```\n'
LABELED_FENCED_BODY='```text\nPreview URL: https://fixture.tailnet.ts.net:9443/\n```\n'
DIFFERENTLY_WORDED_PREVIEW_BODY='Staging review is live at https://preview.tailnet.ts.net:5443/\n'
# The declaration a real ready PR carries, in prose and outside every fence.
DECLARED_PREVIEW_BODY='## Tailscale Preview\n\nPreview URL: https://preview.tailnet.ts.net:5443/\n\nVisual evidence report: https://preview.tailnet.ts.net:5443/__review__/evidence\n\nFeature testing report: https://preview.tailnet.ts.net:5443/__review__/feature-report\n\nPreview head SHA: 27de1405\n'
BOLD_DECLARED_PREVIEW_BODY='## Tailscale Preview\n\n**Preview URL:** https://preview.tailnet.ts.net:5443/\n\n**Visual evidence report:** https://preview.tailnet.ts.net:5443/__review__/evidence\n\n**Feature testing report:** https://preview.tailnet.ts.net:5443/__review__/feature-report\n'

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
printf '%s\t%s\t%s\n' \
  "${FM_TEST_GH_STATE:-OPEN}" "${FM_TEST_GH_DRAFT:-false}" "${FM_TEST_GH_BODY:-}"
SH

# "serve status" answers with whatever mapping the case declares, defaulting to
# no mapping at all so an undeclared case keeps the prompt-alert behavior.
cat > "$FAKEBIN/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TAILSCALE_LOG"
if [ "${1:-}" = serve ]; then
  [ -z "${FM_TEST_TAILSCALE_SERVE:-}" ] || printf '%s\n' "$FM_TEST_TAILSCALE_SERVE"
  exit "${FM_TEST_TAILSCALE_SERVE_RC:-0}"
fi
printf '%s\n' "${FM_TEST_TAILSCALE_IP:-100.89.232.70}"
SH

# Loopback targets answer from their own knobs so a case can hold the local
# service healthy while the captain-facing round trip is slow, or kill the
# listener while the mapping stays published. Tailnet probes past the first
# attempt in a poll use the retry knobs, defaulting to the first attempt's
# result so an unchanged case still fails both budgets.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
target=${!#}
case "$target" in
  http://127.0.0.1:*)
    printf '%s %s' "${FM_TEST_LOOPBACK_CODE:-200}" "${FM_TEST_LOOPBACK_BYTES:-7}"
    exit "${FM_TEST_LOOPBACK_RC:-0}"
    ;;
esac
attempt=$(($(cat "$FM_TEST_CURL_SEQ" 2>/dev/null || printf 0) + 1))
printf '%s\n' "$attempt" > "$FM_TEST_CURL_SEQ"
if [ "$attempt" -gt 1 ]; then
  printf '%s %s' "${FM_TEST_CURL_RETRY_CODE:-${FM_TEST_CURL_CODE:-200}}" \
    "${FM_TEST_CURL_RETRY_BYTES:-${FM_TEST_CURL_BYTES:-7}}"
  exit "${FM_TEST_CURL_RETRY_RC:-${FM_TEST_CURL_RC:-0}}"
fi
printf '%s %s' "${FM_TEST_CURL_CODE:-200}" "${FM_TEST_CURL_BYTES:-7}"
exit "${FM_TEST_CURL_RC:-0}"
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/tailscale" "$FAKEBIN/curl"

cat > "$DEADLINE_ENV" <<'SH'
set -T
trap 'case $BASH_COMMAND in preview_http_ok*PREVIEW_RETRY_CONNECT_SECS*) SECONDS=18; : > "$FM_TEST_DEADLINE_MARKER" ;; esac' DEBUG
SH

reset_logs() {
  : > "$GH_LOG"
  : > "$CURL_LOG"
  : > "$TAILSCALE_LOG"
}

run_poll() {
  : > "$CURL_SEQ"
  FM_TEST_GH_LOG="$GH_LOG" FM_TEST_CURL_LOG="$CURL_LOG" \
    FM_TEST_TAILSCALE_LOG="$TAILSCALE_LOG" FM_TEST_CURL_SEQ="$CURL_SEQ" \
    FM_PR_POLL_TASK_ID=preview-task \
    FM_PR_POLL_STATE="$TMP_ROOT" PATH="$FAKEBIN:$BASE_PATH" "$POLL" --validated \
    github "$URL" github.com example/preview-app 42
}

reset_preview_state() {
  rm -f "$TMP_ROOT/preview-task.preview-outage" \
    "$TMP_ROOT/preview-task.preview-outage-pending" "$SUSPECT"
}

commit_outage() {
  fm_pr_preview_outage_commit "$TMP_ROOT" preview-task "$URL"
}

test_dead_preview_wakes() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=503 FM_PREVIEW_TAILNET_IP=100.89.232.70 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "dead preview did not emit the exact task-and-PR wake"
  [ "$(wc -l < "$GH_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "dead preview used more than one GitHub read"
  assert_grep '--json state,isDraft,body' "$GH_LOG" \
    "GitHub read did not request state, draft status, and body together"
  assert_grep '--resolve preview.tailnet.ts.net:5443:100.89.232.70' "$CURL_LOG" \
    "preview probe was not pinned to the host tailnet IPv4 address"
  assert_grep '--connect-timeout 1 --max-time 2' "$CURL_LOG" \
    "preview probe did not use the bounded short timeouts"
  assert_grep '--noproxy *' "$CURL_LOG" \
    "preview probe could escape through an ambient proxy"
  assert_grep '-q --noproxy' "$CURL_LOG" \
    "preview probe did not disable ambient curl configuration"
  assert_grep '-w %{http_code} %{size_download}' "$CURL_LOG" \
    "preview probe did not measure both status and response bytes"
  commit_outage || fail "dead preview candidate did not commit"

  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net/' \
    FM_TEST_CURL_BYTES=0 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "zero-byte preview did not emit the exact wake"
  commit_outage || fail "zero-byte preview candidate did not commit"
  pass "non-200 and zero-byte preview responses emit one task-and-PR wake"
}

test_dead_preview_deduplicates_until_link_change_or_recovery() {
  local body out
  body='Preview URL: https://preview.tailnet.ts.net:5443/'
  rm -f "$TMP_ROOT/preview-task.preview-outage" \
    "$TMP_ROOT/preview-task.preview-outage-pending"
  reset_logs
  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "first dead preview did not emit a wake"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage" ] \
    || fail "poll committed the outage before durable queueing"
  [ -f "$TMP_ROOT/preview-task.preview-outage-pending" ] \
    || fail "poll did not stage the outage candidate"

  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "uncommitted outage was not retryable after interruption"
  commit_outage || fail "staged outage did not commit after durable queueing"

  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ -z "$out" ] || fail "committed dead preview emitted a duplicate wake"

  out=$(FM_TEST_GH_BODY="$body Updated" FM_TEST_CURL_CODE=503 run_poll)
  [ -z "$out" ] || fail "unrelated PR body change emitted a duplicate wake"

  body='Preview URL: https://replacement.tailnet.ts.net:5443/'
  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "preview link change did not start a new preview outage"
  commit_outage || fail "changed-link outage candidate did not commit"

  out=$(FM_TEST_GH_BODY="$body" run_poll)
  [ -z "$out" ] || fail "preview recovery emitted a wake"

  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "preview failure after recovery did not start a new outage"
  commit_outage || fail "post-recovery outage candidate did not commit"
  pass "dead preview remains retryable until its queued wake commits"
}

test_pending_outage_bypasses_new_corroboration() {
  local body out
  body='Preview URL: https://preview.tailnet.ts.net:5443/'
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "first dead preview did not emit a wake"
  [ -f "$TMP_ROOT/preview-task.preview-outage-pending" ] \
    || fail "first dead preview did not stage its outage candidate"

  reset_logs
  rm -f "$DEADLINE_MARKER"
  out=$(BASH_ENV="$DEADLINE_ENV" FM_TEST_DEADLINE_MARKER="$DEADLINE_MARKER" \
    FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 \
    FM_TEST_CURL_RC=28 FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -f "$DEADLINE_MARKER" ] \
    || fail "pending-outage retry did not cross the probe deadline"
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "the probe deadline suppressed an uncommitted outage retry"
  [ ! -e "$SUSPECT" ] \
    || fail "an uncommitted outage retry created a corroboration record"
  ! grep -q '^serve status$' "$TAILSCALE_LOG" \
    || fail "an uncommitted outage retry consulted local corroboration"

  commit_outage || fail "retried outage candidate did not commit"
  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=503 run_poll)
  [ -z "$out" ] || fail "committed retried outage emitted a duplicate wake"
  reset_preview_state
  pass "a matching pending outage retries before local corroboration"
}

test_link_change_retires_stale_preview_identity() {
  local body_a body_b out
  body_a='Preview URL: https://preview.tailnet.ts.net:5443/'
  body_b='Preview URL: https://replacement.tailnet.ts.net:5443/'
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY="$body_a" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "initial preview outage did not emit a wake"
  commit_outage || fail "initial preview outage did not commit"

  out=$(FM_TEST_GH_BODY="$body_b" FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 \
    FM_TEST_CURL_RC=28 \
    FM_TEST_TAILSCALE_SERVE='https://replacement.tailnet.ts.net:5443 (tailnet only)
|-- / proxy http://127.0.0.1:5443' run_poll)
  [ -z "$out" ] || fail "corroborated replacement preview emitted a wake"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage" ] \
    || fail "replacement preview retained the earlier committed outage"
  [ -f "$SUSPECT" ] \
    || fail "replacement preview did not record its corroborated deferral"

  out=$(FM_TEST_GH_BODY="$body_a" FM_TEST_CURL_CODE=503 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "stale replacement state suppressed the earlier preview outage"
  reset_preview_state
  pass "preview link changes retire stale outage identities"
}

test_tailnet_override_must_match_local_host() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net/' \
    FM_PREVIEW_TAILNET_IP=100.89.232.71 run_poll)
  [ -z "$out" ] || fail "foreign tailnet override emitted a wake"
  [ ! -s "$CURL_LOG" ] || fail "foreign tailnet override reached curl"
  [ "$(wc -l < "$TAILSCALE_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "foreign tailnet override was not checked against the local host"
  pass "tailnet override is accepted only when it matches the local host"
}

test_healthy_preview_is_silent() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' run_poll)
  [ -z "$out" ] || fail "healthy preview emitted a wake"
  [ "$(wc -l < "$GH_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "healthy preview used more than one GitHub read"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "healthy preview was not probed exactly once"
  pass "HTTP 200 preview with a non-empty body stays silent"
}

test_closed_merged_and_draft_prs_skip_previews() {
  local out state
  for state in CLOSED MERGED; do
    reset_logs
    printf '%s\n' stale > "$TMP_ROOT/preview-task.preview-outage"
    printf '%s\n' stale > "$TMP_ROOT/preview-task.preview-outage-pending"
    out=$(FM_TEST_GH_STATE=$state \
      FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' run_poll)
    if [ "$state" = MERGED ]; then
      [ "$out" = merged ] || fail "merged PR lost its existing terminal result"
    else
      [ -z "$out" ] || fail "closed PR emitted a preview wake"
    fi
    [ ! -s "$CURL_LOG" ] || fail "$state PR performed a preview probe"
    [ ! -s "$TAILSCALE_LOG" ] || fail "$state PR resolved a tailnet address"
    [ ! -e "$TMP_ROOT/preview-task.preview-outage" ] \
      || fail "$state PR did not clear the preview outage marker"
    [ ! -e "$TMP_ROOT/preview-task.preview-outage-pending" ] \
      || fail "$state PR did not clear the pending preview outage"
  done

  reset_logs
  printf '%s\n' stale > "$TMP_ROOT/preview-task.preview-outage"
  printf '%s\n' stale > "$TMP_ROOT/preview-task.preview-outage-pending"
  out=$(FM_TEST_GH_DRAFT=true \
    FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' run_poll)
  [ -z "$out" ] || fail "draft PR emitted a preview wake"
  [ ! -s "$CURL_LOG" ] || fail "draft PR performed a preview probe"
  [ ! -s "$TAILSCALE_LOG" ] || fail "draft PR resolved a tailnet address"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage" ] \
    || fail "draft PR did not clear the preview outage marker"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage-pending" ] \
    || fail "draft PR did not clear the pending preview outage"
  pass "closed, merged, and draft PRs do not probe previews"
}

test_dead_preview_reaches_durable_wake_queue_once() {
  local home state out rc wake_count
  home="$TMP_ROOT/watcher-home"
  state="$home/state"
  mkdir -p "$state"
  fm_write_meta "$state/preview-task.meta" \
    'window=fm-preview-task' \
    "pr=$URL"
  fm_pr_poll_prepare "$state" preview-task github "$URL" github.com \
    example/preview-app 42 "$POLL" \
    || fail "could not prepare the authenticated preview poll"
  fm_pr_poll_publish_prepared \
    || fail "could not publish the authenticated preview poll"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  reset_logs

  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=3 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    FM_TEST_GH_LOG="$GH_LOG" FM_TEST_CURL_LOG="$CURL_LOG" \
    FM_TEST_TAILSCALE_LOG="$TAILSCALE_LOG" \
    FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=503 FM_PREVIEW_TAILNET_IP=100.89.232.70 \
    PATH="$FAKEBIN:$BASE_PATH" "$WATCH" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher failed while surfacing the dead preview: $out"
  case "$out" in
    "check: $state/preview-task.check.sh: preview-dead: task=preview-task pr=$URL") ;;
    *) fail "watcher did not surface the exact dead-preview wake: $out" ;;
  esac
  wake_count=$(awk -F '\t' -v payload="check: $state/preview-task.check.sh: preview-dead: task=preview-task pr=$URL" \
    '$5 == payload { count++ } END { print count + 0 }' "$state/.wake-queue")
  [ "$wake_count" -eq 1 ] || fail "durable queue did not contain exactly one dead-preview wake"
  [ -f "$state/preview-task.preview-outage" ] \
    || fail "watcher did not commit the queued preview outage"
  [ ! -e "$state/preview-task.preview-outage-pending" ] \
    || fail "watcher left the queued preview outage pending"
  [ "$(wc -l < "$GH_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "end-to-end watcher used more than one GitHub read"
  if [ -n "${FM_TEST_EVIDENCE_LOG:-}" ]; then
    # This transcript is published in the PR body that ships this poll. The
    # fixture scheme is defanged so no parser, including the one already armed
    # in a home running an older poll, can read the evidence as a live preview
    # declaration. Host, port, tailnet pin, and both budgets stay exact.
    {
      printf 'WATCHER OUTPUT\n%s\n\n' "$out"
      printf 'GITHUB READ\n'
      cat "$GH_LOG"
      printf '\nPINNED PREVIEW PROBE (fixture host, scheme defanged to hxxps)\n'
      sed 's|https://|hxxps://|g' "$CURL_LOG"
      printf '\nDURABLE WAKE QUEUE\n'
      cat "$state/.wake-queue"
      printf '\nOUTAGE STATE\ncommitted=%s pending=%s\n' \
        "$(test -f "$state/preview-task.preview-outage" && printf yes || printf no)" \
        "$(test -e "$state/preview-task.preview-outage-pending" && printf yes || printf no)"
    } > "$FM_TEST_EVIDENCE_LOG"
  fi
  pass "dead preview produces exactly one durable watcher wake naming its task and PR"
}

# The reported false alert: the listener never restarted, loopback answered in
# milliseconds, and the tailnet round trip simply missed a two-second budget on
# a loaded host. One bounded retry inside the same poll absorbs it.
test_bounded_retry_absorbs_a_slow_tailnet_probe() {
  local out
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_CURL_RETRY_CODE=200 FM_TEST_CURL_RETRY_BYTES=4096 \
    FM_TEST_CURL_RETRY_RC=0 FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "a preview that answered on the bounded retry emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 2 ] \
    || fail "slow preview probe was not retried exactly once"
  assert_grep '--connect-timeout 2 --max-time 5' "$CURL_LOG" \
    "the retry did not use the bounded larger budget"
  [ "$(grep -c -- '--resolve preview.tailnet.ts.net:5443:100.89.232.70' "$CURL_LOG")" -eq 2 ] \
    || fail "the retry was not pinned to the host tailnet IPv4 address"
  [ ! -e "$SUSPECT" ] || fail "a recovered retry left an unconfirmed-failure record"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage-pending" ] \
    || fail "a recovered retry staged a preview outage"
  pass "a slow tailnet round trip that answers on one bounded retry stays silent"
}

# Corroboration buys exactly one check interval and never more: the second
# consecutive captain-facing failure wakes firstmate even while the local
# service keeps answering.
test_corroborated_transient_failure_defers_exactly_one_check() {
  local out
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "a corroborated first failure emitted a wake"
  [ -f "$SUSPECT" ] || fail "a corroborated first failure was not recorded"
  [ "$(fm_pr_file_mode "$SUSPECT")" = 600 ] \
    || fail "the unconfirmed-failure record is not private"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage-pending" ] \
    || fail "a corroborated first failure staged a preview outage"
  assert_grep 'http://127.0.0.1:5443/' "$CURL_LOG" \
    "the corroborating probe did not use the served loopback target and link path"
  assert_grep '--connect-timeout 1 --max-time 2' "$CURL_LOG" \
    "the corroborating probe was not bounded"
  [ "$(grep -c -- '--resolve' "$CURL_LOG")" -eq 2 ] \
    || fail "the corroborating loopback probe was pinned like a tailnet probe"

  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "a persistent captain-facing failure did not wake on the next check"
  commit_outage || fail "confirmed outage candidate did not commit"

  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "a committed confirmed outage emitted a duplicate wake"
  reset_preview_state
  pass "a corroborated failure defers one check, then wakes once and deduplicates"
}

test_corroborated_failure_recovers_without_a_wake() {
  local body out
  body='Preview URL: https://preview.tailnet.ts.net:5443/'
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 \
    FM_TEST_CURL_RC=28 FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "a corroborated first failure emitted a wake"
  [ -f "$SUSPECT" ] || fail "a corroborated first failure was not recorded"

  out=$(FM_TEST_GH_BODY="$body" FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "recovery after a deferred failure emitted a wake"
  [ ! -e "$SUSPECT" ] || fail "recovery did not retire the unconfirmed-failure record"

  out=$(FM_TEST_GH_BODY="$body" FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 \
    FM_TEST_CURL_RC=28 FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ -z "$out" ] || fail "a failure after recovery did not start a fresh deferral"
  [ -f "$SUSPECT" ] || fail "a failure after recovery was not recorded"
  reset_preview_state
  pass "recovery clears the deferral so a later failure starts fresh"
}

# Local evidence is only ever evidence against a transient alert. Whenever the
# listener is gone or replaced by something that does not answer, the wake is
# prompt even though the mapping is still published.
test_dead_or_replaced_listener_alerts_immediately() {
  local out
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_LOOPBACK_CODE=000 FM_TEST_LOOPBACK_BYTES=0 FM_TEST_LOOPBACK_RC=7 \
    FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "a dead listener behind a published mapping did not wake promptly"
  [ ! -e "$SUSPECT" ] || fail "a dead listener was recorded as a deferrable failure"
  reset_preview_state

  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_LOOPBACK_CODE=503 FM_TEST_LOOPBACK_BYTES=0 \
    FM_TEST_TAILSCALE_SERVE='https://preview.tailnet.ts.net:5443 (tailnet only)
|-- / proxy http://127.0.0.1:9999' run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "a replaced listener that does not answer did not wake promptly"
  reset_preview_state
  pass "a dead or replaced local listener wakes on the first failing check"
}

test_absent_or_mismatched_mapping_alerts_immediately() {
  local out serve label
  while IFS='|' read -r label serve; do
    [ -n "$label" ] || continue
    reset_preview_state
    reset_logs
    out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
      FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
      FM_TEST_TAILSCALE_SERVE="$(printf '%b' "$serve")" run_poll)
    [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
      || fail "$label did not wake on the first failing check"
    [ ! -e "$SUSPECT" ] || fail "$label was recorded as a deferrable failure"
    ! grep -q 'http://127.0.0.1' "$CURL_LOG" \
      || fail "$label was corroborated against an unbound loopback target"
  done <<'EOF'
an absent serve mapping|
a mapping for another port|https://preview.tailnet.ts.net:5999 (tailnet only)\n|-- / proxy http://127.0.0.1:5443
a mapping for another host|https://other.tailnet.ts.net:5443 (tailnet only)\n|-- / proxy http://127.0.0.1:5443
a non-loopback target|https://preview.tailnet.ts.net:5443 (tailnet only)\n|-- / proxy http://10.0.0.5:5443
a sub-path handler only|https://preview.tailnet.ts.net:5443 (tailnet only)\n|-- /app proxy http://127.0.0.1:5443
EOF

  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=000 FM_TEST_CURL_BYTES=0 FM_TEST_CURL_RC=28 \
    FM_TEST_TAILSCALE_SERVE="$HEALTHY_SERVE" FM_TEST_TAILSCALE_SERVE_RC=1 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "an unreadable serve mapping did not wake on the first failing check"
  reset_preview_state
  pass "an absent, mismatched, non-loopback, or unreadable mapping wakes promptly"
}

# The probe deadline bounds the work; it must never become a silent off switch.
# bash adopts SECONDS from its environment, so the poll sets its own baseline.
test_probe_deadline_baseline_is_not_inherited() {
  local out
  reset_preview_state
  reset_logs
  out=$(SECONDS=99999 FM_TEST_GH_BODY='Preview URL: https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=503 FM_TEST_CURL_BYTES=0 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "an inherited elapsed-time baseline suppressed preview probing"
  [ -s "$CURL_LOG" ] || fail "an inherited elapsed-time baseline skipped every probe"
  reset_preview_state
  pass "the probe deadline measures from a baseline the poll sets itself"
}

# The self-hosting regression: this repository's own PR documented the poll,
# and an evidence URL inside a fence became the preview the poll then monitored.
test_fenced_and_prose_links_are_distinguished() {
  local out
  reset_preview_state
  reset_logs
  printf '%s\n' stale > "$TMP_ROOT/preview-task.preview-outage"
  out=$(FM_TEST_GH_BODY="$FENCED_EVIDENCE_BODY" FM_TEST_CURL_CODE=503 \
    FM_TEST_CURL_BYTES=0 run_poll)
  [ -z "$out" ] || fail "a fenced transcript example was monitored as a preview"
  [ ! -s "$CURL_LOG" ] || fail "a fenced transcript example was probed"
  [ ! -s "$TAILSCALE_LOG" ] || fail "a fenced transcript example resolved a tailnet address"
  [ ! -e "$TMP_ROOT/preview-task.preview-outage" ] \
    || fail "a PR declaring no preview kept a committed outage identity"
  [ ! -e "$SUSPECT" ] || fail "a fenced transcript example was recorded as a failure"

  reset_logs
  out=$(FM_TEST_GH_BODY="$DIFFERENTLY_WORDED_PREVIEW_BODY" run_poll)
  [ -z "$out" ] || fail "a differently worded healthy declaration emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "a differently worded prose declaration was not monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$CONTAINER_LIKE_CODE_BODY" run_poll)
  [ -z "$out" ] || fail "container-like transcript text emitted a wake"
  [ ! -s "$CURL_LOG" ] || fail "container-like transcript text exposed a fixture URL"
  [ ! -s "$TAILSCALE_LOG" ] \
    || fail "container-like transcript text resolved a tailnet address"

  reset_logs
  out=$(FM_TEST_GH_BODY="$LABELED_FENCED_BODY" run_poll)
  [ -z "$out" ] || fail "a canonical label inside a fenced transcript emitted a wake"
  [ ! -s "$CURL_LOG" ] || fail "a canonical label inside a fenced transcript was probed"
  [ ! -s "$TAILSCALE_LOG" ] \
    || fail "a canonical label inside a fenced transcript resolved a tailnet address"

  reset_logs
  out=$(FM_TEST_GH_BODY="$FOUR_BACKTICK_BODY" run_poll)
  [ -z "$out" ] || fail "a declaration beside nested example code emitted a wake"
  ! grep -q 'fixture.tailnet.ts.net' "$CURL_LOG" \
    || fail "a fenced nested example URL was probed"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "a prose declaration after nested example code was not monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$LITERAL_BACKSLASH_N_BODY" run_poll)
  [ -z "$out" ] || fail "a fenced literal backslash-n transcript emitted a wake"
  [ ! -s "$CURL_LOG" ] \
    || fail "a literal backslash-n transcript exposed a fixture URL"
  [ ! -s "$TAILSCALE_LOG" ] \
    || fail "a literal backslash-n transcript resolved a tailnet address"
  reset_preview_state
  pass "fenced examples are ignored while prose declarations are monitored"
}

test_declarations_after_synthetic_code_are_monitored() {
  local body label out
  while IFS='|' read -r label body; do
    reset_logs
    out=$(FM_TEST_GH_BODY="$body" run_poll)
    [ -z "$out" ] || fail "$label emitted a wake for a healthy preview"
    [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
      || fail "$label hid a following prose declaration"
  done <<EOF
four-space-indented backtick line|$INDENTED_NON_FENCE_BODY
backtick in fence info string|$BACKTICK_INFO_NON_FENCE_BODY
EOF
  reset_preview_state
  pass "prose declarations after synthetic code stay monitored"
}

test_container_fences_and_declarations() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY="$BLOCKQUOTED_FENCE_BODY" run_poll)
  [ -z "$out" ] || fail "a blockquoted fenced example emitted a wake"
  [ ! -s "$CURL_LOG" ] || fail "a blockquoted fenced fixture was probed"
  [ ! -s "$TAILSCALE_LOG" ] || fail "a blockquoted fenced fixture resolved a tailnet address"

  reset_logs
  out=$(FM_TEST_GH_BODY="$BLOCKQUOTED_DECLARATION_BODY" run_poll)
  [ -z "$out" ] || fail "a healthy blockquoted declaration emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "a blockquoted prose declaration was not monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$LIST_CONTAINER_BODY" run_poll)
  [ -z "$out" ] || fail "a list-contained healthy declaration emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "a list-contained prose declaration was not monitored"
  reset_preview_state
  pass "container declarations stay monitored while fenced fixtures stay ignored"
}

# Disconfirming cases: every declaration a ready PR carries stays
# monitored, including when the same body also quotes fenced fixture hosts.
test_declared_preview_links_stay_monitored() {
  local out
  reset_preview_state
  reset_logs
  out=$(FM_TEST_GH_BODY="$DECLARED_PREVIEW_BODY" run_poll)
  [ -z "$out" ] || fail "a healthy declared preview emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 3 ] \
    || fail "the declared preview, visual evidence, and feature report were not all probed"
  assert_grep 'https://preview.tailnet.ts.net:5443/__review__/evidence' "$CURL_LOG" \
    "the declared visual evidence report was not monitored"
  assert_grep 'https://preview.tailnet.ts.net:5443/__review__/feature-report' "$CURL_LOG" \
    "the declared feature testing report was not monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$BOLD_DECLARED_PREVIEW_BODY" run_poll)
  [ -z "$out" ] || fail "healthy bold canonical declarations emitted a wake"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 3 ] \
    || fail "the three bold canonical declarations were not all probed"
  assert_grep 'https://preview.tailnet.ts.net:5443/__review__/evidence' "$CURL_LOG" \
    "the bold visual evidence declaration was not monitored"
  assert_grep 'https://preview.tailnet.ts.net:5443/__review__/feature-report' "$CURL_LOG" \
    "the bold feature testing declaration was not monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$DECLARED_PREVIEW_BODY$FENCED_EVIDENCE_BODY" run_poll)
  [ -z "$out" ] || fail "a declared preview beside fenced evidence emitted a wake"
  ! grep -q 'fixture.tailnet.ts.net' "$CURL_LOG" \
    || fail "a fenced fixture host was probed alongside a real declaration"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 3 ] \
    || fail "fenced evidence changed which declared links were monitored"

  reset_logs
  out=$(FM_TEST_GH_BODY="$DECLARED_PREVIEW_BODY$FENCED_EVIDENCE_BODY" \
    FM_TEST_CURL_CODE=503 FM_TEST_CURL_BYTES=0 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "a genuinely dead declared preview stopped waking"
  reset_preview_state

  # The same declaration delivered with real newlines rather than the forge's
  # escaped field must resolve identically.
  reset_logs
  out=$(FM_TEST_GH_BODY="$(printf 'Preview URL: https://preview.tailnet.ts.net:5443/\n')" run_poll)
  [ -z "$out" ] || fail "a real-newline body emitted a wake for a healthy preview"
  [ "$(wc -l < "$CURL_LOG" | tr -d '[:space:]')" -eq 1 ] \
    || fail "a real-newline body did not monitor its declared preview"
  reset_preview_state
  pass "declared preview, visual evidence, and feature report links stay monitored"
}

test_fenced_and_prose_links_are_distinguished
test_declarations_after_synthetic_code_are_monitored
test_container_fences_and_declarations
test_declared_preview_links_stay_monitored
test_dead_preview_wakes
test_dead_preview_deduplicates_until_link_change_or_recovery
test_pending_outage_bypasses_new_corroboration
test_link_change_retires_stale_preview_identity
test_tailnet_override_must_match_local_host
test_healthy_preview_is_silent
test_closed_merged_and_draft_prs_skip_previews
test_bounded_retry_absorbs_a_slow_tailnet_probe
test_corroborated_transient_failure_defers_exactly_one_check
test_corroborated_failure_recovers_without_a_wake
test_dead_or_replaced_listener_alerts_immediately
test_absent_or_mismatched_mapping_alerts_immediately
test_probe_deadline_baseline_is_not_inherited
test_dead_preview_reaches_durable_wake_queue_once
