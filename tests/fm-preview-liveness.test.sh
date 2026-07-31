#!/usr/bin/env bash
# Preview-liveness coverage for the authenticated per-task PR watcher.
#
# The watcher itself already has coverage proving any non-empty authenticated
# PR-poll result becomes a check wake.
# This suite owns the preview-specific contract: one GitHub read supplies state,
# draft status, and body; only open ready PRs are probed; curl is pinned to this
# host's tailnet IPv4 address with short timeouts; a non-200 or empty response
# emits one task-and-PR wake line; and a healthy preview stays silent.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-preview-liveness)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
GH_LOG="$TMP_ROOT/gh.log"
CURL_LOG="$TMP_ROOT/curl.log"
TAILSCALE_LOG="$TMP_ROOT/tailscale.log"
URL=https://github.com/example/preview-app/pull/42

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
printf '%s\t%s\t%s\n' \
  "${FM_TEST_GH_STATE:-OPEN}" "${FM_TEST_GH_DRAFT:-false}" "${FM_TEST_GH_BODY:-}"
SH

cat > "$FAKEBIN/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TAILSCALE_LOG"
printf '%s\n' "${FM_TEST_TAILSCALE_IP:-100.89.232.70}"
SH

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
printf '%s %s' "${FM_TEST_CURL_CODE:-200}" "${FM_TEST_CURL_BYTES:-7}"
exit "${FM_TEST_CURL_RC:-0}"
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/tailscale" "$FAKEBIN/curl"

reset_logs() {
  : > "$GH_LOG"
  : > "$CURL_LOG"
  : > "$TAILSCALE_LOG"
}

run_poll() {
  FM_TEST_GH_LOG="$GH_LOG" FM_TEST_CURL_LOG="$CURL_LOG" \
    FM_TEST_TAILSCALE_LOG="$TAILSCALE_LOG" FM_PR_POLL_TASK_ID=preview-task \
    PATH="$FAKEBIN:$BASE_PATH" "$POLL" --validated \
    github "$URL" github.com example/preview-app 42
}

test_dead_preview_wakes() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY='Review at https://preview.tailnet.ts.net:5443/' \
    FM_TEST_CURL_CODE=503 run_poll)
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

  reset_logs
  out=$(FM_TEST_GH_BODY='https://preview.tailnet.ts.net/' \
    FM_TEST_CURL_BYTES=0 run_poll)
  [ "$out" = "preview-dead: task=preview-task pr=$URL" ] \
    || fail "zero-byte preview did not emit the exact wake"
  pass "non-200 and zero-byte preview responses emit one task-and-PR wake"
}

test_healthy_preview_is_silent() {
  local out
  reset_logs
  out=$(FM_TEST_GH_BODY='Review at https://preview.tailnet.ts.net:5443/' run_poll)
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
    out=$(FM_TEST_GH_STATE=$state \
      FM_TEST_GH_BODY='https://preview.tailnet.ts.net:5443/' run_poll)
    if [ "$state" = MERGED ]; then
      [ "$out" = merged ] || fail "merged PR lost its existing terminal result"
    else
      [ -z "$out" ] || fail "closed PR emitted a preview wake"
    fi
    [ ! -s "$CURL_LOG" ] || fail "$state PR performed a preview probe"
    [ ! -s "$TAILSCALE_LOG" ] || fail "$state PR resolved a tailnet address"
  done

  reset_logs
  out=$(FM_TEST_GH_DRAFT=true \
    FM_TEST_GH_BODY='https://preview.tailnet.ts.net:5443/' run_poll)
  [ -z "$out" ] || fail "draft PR emitted a preview wake"
  [ ! -s "$CURL_LOG" ] || fail "draft PR performed a preview probe"
  [ ! -s "$TAILSCALE_LOG" ] || fail "draft PR resolved a tailnet address"
  pass "closed, merged, and draft PRs do not probe previews"
}

test_dead_preview_wakes
test_healthy_preview_is_silent
test_closed_merged_and_draft_prs_skip_previews
